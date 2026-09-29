import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../diagnostics/performance_interceptor.dart';
import 'request_work_scope.dart';

/// Limits connection/header work. Bodies still drain on the existing client.
/// A queued cancellation settles immediately and never touches the transport.
class ScheduledHttpAdapter implements HttpClientAdapter {
  ScheduledHttpAdapter(
    this.inner, {
    this.slots = 6,
    this.maxWait = const Duration(seconds: 5),
  }) : _free = slots;
  final HttpClientAdapter inner;
  final int slots;
  final Duration maxWait;
  int _free;
  bool _closed = false;
  final _clock = Stopwatch()..start();
  final List<_Waiter> _waiting = [];
  int get queued => _waiting.length;
  int get running => slots - _free;

  DioException _canceled(RequestOptions options) =>
      DioException.requestCancelled(
        requestOptions: options,
        reason: _closed ? 'adapter closed' : 'request canceled before dispatch',
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed || (options.cancelToken?.isCancelled ?? false))
      throw _canceled(options);
    final path = options.uri.path.toLowerCase();
    final priority = path.endsWith('/playbackinfo')
        ? 0
        : options.extra[RequestWorkScope.priorityExtra] as int? ??
              RequestPriority.normal.index;
    final waiter = _Waiter(options, priority, _clock.elapsedMicroseconds);
    final trace = PerformanceInterceptor.span(options);
    trace?.mark('http.queued', {
      'queued': queued,
      'free': _free,
      'priority': priority,
    });
    _waiting.add(waiter);
    // Install cancellation before admission. The same state transition owns
    // the permit whether cancellation races the queue or an admitted fetch.
    cancelFuture?.then((_) {
      waiter.canceled = true;
      if (_waiting.remove(waiter)) {
        waiter.ready.complete(false);
        trace?.mark('http.queue_canceled', {'queued': queued});
      }
    });
    _drain();
    final admitted = await waiter.ready.future;
    if (!admitted) throw _canceled(options);
    try {
      if (_closed ||
          waiter.canceled ||
          (options.cancelToken?.isCancelled ?? false))
        throw _canceled(options);
      final at = trace?.elapsedUs;
      trace?.mark('http.dispatched', {
        'durationUs': _clock.elapsedMicroseconds - waiter.atUs,
        'priority': priority,
        'queued': queued,
      });
      final body = await inner.fetch(options, requestStream, cancelFuture);
      PerformanceInterceptor.headersReceived(options);
      trace?.mark('http.headers', {
        'status': body.statusCode,
        'durationUs': trace.elapsedUs - at!,
      });
      return body;
    } finally {
      _free++;
      _drain();
    }
  }

  void _drain() {
    while (!_closed && _free > 0 && _waiting.isNotEmpty) {
      final aged = _waiting.indexWhere(
        (w) => _clock.elapsedMicroseconds - w.atUs >= maxWait.inMicroseconds,
      );
      var index = aged;
      if (index < 0) {
        index = 0;
        for (var i = 1; i < _waiting.length; i++) {
          if (_waiting[i].priority < _waiting[index].priority) index = i;
        }
      }
      final waiter = _waiting.removeAt(index);
      _free--;
      waiter.ready.complete(true);
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final waiter in _waiting) {
      waiter.ready.complete(false);
    }
    _waiting.clear();
    inner.close(force: force);
  }
}

class _Waiter {
  _Waiter(this.options, this.priority, this.atUs);
  final RequestOptions options;
  final int priority, atUs;
  final ready = Completer<bool>();
  bool canceled = false;
}
