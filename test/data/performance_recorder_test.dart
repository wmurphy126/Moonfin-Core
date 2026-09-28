import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/performance_recorder.dart';
import 'package:moonfin/data/services/performance_store.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:server_core/server_core.dart' hide PackageInfo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moonfin/performance');
  late Directory directory;
  late PerformanceStore store;
  late PerformanceRecorder recorder;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'moonfin-performance-test-',
    );
    store = PerformanceStore(directory: directory.path);
    recorder = PerformanceRecorder.forTesting(store);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    PackageInfo.setMockInitialValues(
      appName: 'Moonfin',
      packageName: 'test',
      version: '2.6.0',
      buildNumber: '1',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'cpuTimeMs': 100,
            'elapsedRealtimeMs': 1000,
            'pssKiB': 40960,
            'model': 'test',
            'sdk': 36,
          },
        );
  });
  tearDown(() async {
    await recorder.stop();
    recorder.dispose();
    PerformanceTrace.sink = null;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'records a first frame, marker and resources, then detaches the sink',
    () async {
      await recorder.start();
      expect(await store.exists(), isTrue);
      recorder.playTapped();
      final generation = recorder.mediaSourceOpened();
      recorder.mediaEvent('firstFrameRendered', {
        'diagnosticGeneration': generation,
        'nativeUs': 123,
      });
      recorder.marker();
      await recorder.stop();
      expect(PerformanceTrace.enabled, isFalse);
      final report = (await recorder.report())!;
      expect(report, contains('play.launch: n=1'));
      expect(report, contains('problem markers: 1'));
      expect(report, contains('40960'));
      expect(report, contains('media.firstFrameRendered'));
      PerformanceTrace.event('late.operation');
      recorder.mediaEvent('firstFrameRendered', {
        'diagnosticGeneration': generation,
      });
      expect(await recorder.report(), report);
    },
  );

  test('old player events and previews cannot complete a new launch', () async {
    await recorder.start();
    final old = recorder.mediaSourceOpened();
    await recorder.stop();
    await recorder.start();
    recorder.playTapped();
    final current = recorder.mediaSourceOpened();
    recorder.mediaEvent('firstFrameRendered', {'diagnosticGeneration': old});
    recorder.mediaEvent('firstFrameRendered', {'diagnosticGeneration': 0});
    recorder.mediaEvent('firstFrameRendered', {});
    recorder.mediaEvent('firstFrameRendered', {
      'diagnosticGeneration': current,
    });
    final report = (await recorder.report())!;
    expect(report, contains('media.firstFrameRendered: 1'));
    expect(report, contains('play.launch: n=1'));
  });

  test('late resource replies cannot modify a stopped recording', () async {
    final reply = Completer<Map<String, Object?>>();
    final requested = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) {
          requested.complete();
          return reply.future;
        });
    final starting = recorder.start();
    await requested.future;
    await recorder.stop();
    reply.complete({'pssKiB': 999999});
    await starting;
    expect(recorder.recording, isFalse);
    expect((await recorder.report())!, isNot(contains('999999')));
    expect(PerformanceTrace.enabled, isFalse);
  });

  test(
    'journals survive restart and rotate only the three owned recordings',
    () async {
      for (var session = 1; session <= 4; session++) {
        await store.start();
        await store.append(['event$session'], 'summary$session');
      }
      final reopened = PerformanceStore(directory: directory.path);
      expect(await reopened.read(), contains('event4'));
      expect(
        await File('${directory.path}/previous1.events').readAsString(),
        contains('event3'),
      );
      expect(
        await File('${directory.path}/previous2.events').readAsString(),
        contains('event2'),
      );
      expect(directory.listSync().length, 6);
    },
  );

  test(
    'disk journal rejects oversized batches without growing past its cap',
    () async {
      await store.start();
      expect(await store.append(['small event'], 'summary'), isTrue);
      expect(await store.append(['x' * (12 * 1024 * 1024)], 'full'), isFalse);
      expect(
        await File('${directory.path}/current.events').length(),
        lessThan(1024),
      );
      expect(await store.read(), contains('small event'));
    },
  );
}
