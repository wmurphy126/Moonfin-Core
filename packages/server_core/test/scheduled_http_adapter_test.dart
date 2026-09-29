import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';
import 'package:server_core/src/network/scheduled_http_adapter.dart';
import 'package:test/test.dart';

class _Transport implements HttpClientAdapter {
  final paths = <String>[];
  final pending = <Completer<ResponseBody>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    paths.add(options.path);
    final reply = Completer<ResponseBody>();
    pending.add(reply);
    return reply.future;
  }

  void reply(int index) =>
      pending[index].complete(ResponseBody.fromString('{}', 200));
  @override
  void close({bool force = false}) {}
}

void main() {
  Future<void> tick() => Future<void>.delayed(Duration.zero);
  test(
    'foreground precedes background, canceled waiters never dispatch',
    () async {
      final transport = _Transport();
      final adapter = ScheduledHttpAdapter(transport, slots: 1);
      final active = adapter.fetch(RequestOptions(path: '/active'), null, null);
      await tick();
      final canceled = Completer<void>();
      final abandoned = adapter.fetch(
        RequestOptions(path: '/abandoned'),
        null,
        canceled.future,
      );
      final rejected = expectLater(abandoned, throwsA(isA<DioException>()));
      final background = adapter.fetch(
        RequestOptions(
          path: '/background',
          extra: {RequestWorkScope.priorityExtra: 2},
        ),
        null,
        null,
      );
      final playback = adapter.fetch(
        RequestOptions(path: '/Items/1/PlaybackInfo'),
        null,
        null,
      );
      canceled.complete();
      await rejected;
      transport.reply(0);
      await active;
      await tick();
      expect(transport.paths, ['/active', '/Items/1/PlaybackInfo']);
      transport.reply(1);
      await playback;
      await tick();
      transport.reply(2);
      await background;
      expect(adapter.running, 0);
      expect(adapter.queued, 0);
    },
  );

  test(
    'aging, close, inner errors and admission cancellation release permits',
    () async {
      final transport = _Transport();
      final adapter = ScheduledHttpAdapter(
        transport,
        slots: 1,
        maxWait: Duration.zero,
      );
      final first = adapter.fetch(RequestOptions(path: '/first'), null, null);
      final canceled = Completer<void>();
      final old = adapter.fetch(
        RequestOptions(
          path: '/old',
          extra: {RequestWorkScope.priorityExtra: 2},
        ),
        null,
        canceled.future,
      );
      final oldCheck = expectLater(old, throwsA(isA<DioException>()));
      final newer = adapter.fetch(
        RequestOptions(path: '/Items/1/PlaybackInfo'),
        null,
        null,
      );
      final newCheck = expectLater(newer, throwsA(isA<DioException>()));
      await tick();
      transport.reply(0);
      canceled.complete();
      await first;
      await oldCheck;
      await tick();
      // The foreground either acquired its permit or was still queued. Closing
      // settles waiting work; a transport failure releases an admitted permit.
      adapter.close(force: true);
      if (transport.pending.length > 1) {
        transport.pending[1].completeError(
          DioException(requestOptions: RequestOptions(path: '/failure')),
        );
      }
      await newCheck;
      expect(adapter.running, 0);
      expect(adapter.queued, 0);
    },
  );

  test(
    'scope reaches Dio adapter and detached shared reads outlive the owner',
    () async {
      final transport = _Transport();
      final adapter = ScheduledHttpAdapter(transport, slots: 1);
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(RequestScopeInterceptor());
      final owner = RequestWorkScope(priority: RequestPriority.background);
      final occupying = dio.get('/occupying');
      await tick();
      final exclusive = owner.run(() => dio.get('/exclusive'));
      final exclusiveCheck = expectLater(
        exclusive,
        throwsA(isA<DioException>()),
      );
      final shared = owner.run(
        () => RequestWorkScope.detached(() => dio.get('/shared')),
      );
      await tick();
      owner.cancel();
      await exclusiveCheck;
      transport.reply(0);
      await occupying;
      await tick();
      expect(transport.paths, ['/occupying', '/shared']);
      transport.reply(1);
      await shared;
      dio.close(force: true);
    },
  );
}
