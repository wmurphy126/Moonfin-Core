import 'dart:async';
import 'package:dio/dio.dart';

enum RequestPriority { foreground, normal, background }

/// Cancellation belongs to a consumer, never to a URL. Repositories that share
/// a read across consumers must start that read with [detached].
class RequestWorkScope {
  RequestWorkScope({this.priority = RequestPriority.normal});
  final RequestPriority priority;
  final _cancel = CancelToken();
  static final _ownerKey = Object(), _priorityKey = Object();
  static const priorityExtra = 'moonfin.requestPriority';
  bool get isCanceled => _cancel.isCancelled;
  Future<void> get whenCanceled => _cancel.whenCancel.then((_) {});
  void cancel() => _cancel.cancel('request owner finished');
  Future<T> run<T>(Future<T> Function() body) => runZoned(() {
    if (isCanceled) throw _cancel.cancelError!;
    return body();
  }, zoneValues: {_ownerKey: this, _priorityKey: priority});

  static Future<T> withPriority<T>(
    RequestPriority priority,
    Future<T> Function() body,
  ) => runZoned(body, zoneValues: {_priorityKey: priority});
  static Future<T> detached<T>(Future<T> Function() body) => runZoned(
    body,
    zoneValues: {_ownerKey: null, _priorityKey: RequestPriority.normal},
  );
}

class RequestScopeInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final owner = Zone.current[RequestWorkScope._ownerKey] as RequestWorkScope?;
    if (owner?.isCanceled ?? false) {
      handler.reject(
        DioException.requestCancelled(
          requestOptions: options,
          reason: 'request owner finished',
        ),
      );
      return;
    }
    options.cancelToken ??= owner?._cancel;
    options.extra.putIfAbsent(
      RequestWorkScope.priorityExtra,
      () =>
          (Zone.current[RequestWorkScope._priorityKey] as RequestPriority? ??
                  RequestPriority.normal)
              .index,
    );
    handler.next(options);
  }
}
