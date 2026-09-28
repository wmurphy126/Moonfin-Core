import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/performance_recording.dart';
import 'package:server_core/server_core.dart';

class _Adapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{"privateTitle":"Never record me"}',
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

void main() {
  tearDown(() {
    PerformanceTrace.sink = null;
    PerformanceTrace.resetAliases();
  });

  test('recording remains bounded and reports dropped events', () {
    final data = PerformanceRecording(maxBytes: 300);
    for (var i = 0; i < 1000; i++) {
      data.add('resources.sample', {'pssKiB': i});
    }
    final lines = data.drain();
    expect(lines.join().length, lessThanOrEqualTo(300));
    expect(data.dropped, greaterThan(0));
    expect(jsonDecode(lines.last)['pssKiB'], 999);
    expect(data.summary(complete: true), contains('999.0'));
  });

  test('duration summary and unfinished work survive journal draining', () {
    final data = PerformanceRecording();
    data.add('span.begin', {'id': 1, 'name': 'play.launch'});
    data.add('span.begin', {'id': 2, 'name': 'collections.membership'});
    data.add('span.end', {
      'id': 1,
      'name': 'play.launch',
      'durationUs': 40000000,
    });
    data.drain();
    final report = data.summary(complete: true);
    expect(report, contains('max=40000.0'));
    expect(report, contains('Unfinished spans at checkpoint: 1'));
    expect(report, contains('collections.membership'));
  });

  test(
    'no secrets, nested bodies or free text can enter structured attributes',
    () {
      final data = PerformanceRecording();
      data.add('sample', {
        'token': 'secret123',
        'authorization': 'Bearer bad',
        'title': 'My film',
        'query': 'private query',
        'url': 'https://secret.example/token',
        'deviceId': 'persistent',
        'deviceName': 'Private phone',
        'message': 'secret exception text',
        'body': {'private': true},
        'decoder': 'https://secret.example',
        'count': 3,
      });
      final line = data.drain().single;
      for (final text in [
        'secret',
        'private',
        'Private',
        'persistent',
        'Bearer',
        'My film',
      ]) {
        expect(line, isNot(contains(text)));
      }
      expect(jsonDecode(line)['count'], 3);
    },
  );

  test(
    'endpoint normalization retains operation but excludes IDs and queries',
    () {
      final path = PerformanceInterceptor.endpoint(
        Uri.parse(
          'https://private.example/Users/alice/Items/movie123/PlaybackInfo?api_key=secret&SearchTerm=personal',
        ),
      );
      expect(path, '/users/:id/items/:id/playbackinfo');
    },
  );

  test(
    'network requests keep behavior and expose no request/response content',
    () async {
      final recording = PerformanceRecording();
      PerformanceTrace.sink = recording.add;
      final dio = Dio()..httpClientAdapter = _Adapter();
      dio.interceptors.add(PerformanceInterceptor());
      final response = await dio.get(
        'https://private.example/Items/movie123?api_key=secret',
      );
      expect(response.data['privateTitle'], 'Never record me');
      final text = recording.drain().join('\n');
      expect(text, contains('http.request'));
      expect(text, contains('span.end'));
      for (final value in [
        'private.example',
        'movie123',
        'secret',
        'Never record me',
      ]) {
        expect(text, isNot(contains(value)));
      }
      expect(recording.summary(complete: true), contains('GET /items/:id'));
      dio.close();
    },
  );

  test(
    'spans finish once and stale completions cannot enter a new recording',
    () {
      final first = PerformanceRecording();
      PerformanceTrace.sink = first.add;
      final done = PerformanceTrace.begin('test')!;
      done.end();
      done.end();
      expect(
        first.drain().where((line) => line.contains('span.end')),
        hasLength(1),
      );
      final old = PerformanceTrace.begin('old')!;
      final second = PerformanceRecording();
      PerformanceTrace.sink = second.add;
      old.mark('late');
      old.end();
      expect(second.drain(), isEmpty);
    },
  );

  test(
    'async children retain their owning operation and failures propagate',
    () async {
      final events = <Map<String, Object?>>[];
      PerformanceTrace.sink = (event, data) =>
          events.add({'event': event, ...data});
      await PerformanceTrace.measure('parent', () async {
        await Future<void>.delayed(Duration.zero);
        await PerformanceTrace.measure('child', () async => 7);
      });
      final parent = events.firstWhere(
        (e) => e['event'] == 'span.begin' && e['name'] == 'parent',
      );
      final child = events.firstWhere(
        (e) => e['event'] == 'span.begin' && e['name'] == 'child',
      );
      expect(child['parent'], parent['id']);
      await expectLater(
        PerformanceTrace.measure(
          'error',
          () async => throw StateError('expected'),
        ),
        throwsStateError,
      );
      expect(events.last['outcome'], 'error');
    },
  );

  test('a broken diagnostic sink cannot break application work', () async {
    PerformanceTrace.sink = (_, _) => throw StateError('diagnostics failed');
    expect(await PerformanceTrace.measure('work', () async => 9), 9);
    PerformanceTrace.sink = null;
    expect(await PerformanceTrace.measure('off', () async => 10), 10);
  });

  test(
    'concurrent progress requests are visible separately from other APIs',
    () {
      final data = PerformanceRecording();
      for (var id = 1; id <= 3; id++) {
        data.add('span.begin', {
          'id': id,
          'name': 'http.request',
          'endpoint': '/sessions/playing/progress',
        });
      }
      data.add('span.end', {'id': 1, 'name': 'http.request', 'durationUs': 1});
      expect(
        data.summary(complete: true),
        contains('/sessions/playing/progress: 3'),
      );
      expect(
        data.summary(complete: true),
        contains('Unfinished spans at checkpoint: 2'),
      );
    },
  );
}
