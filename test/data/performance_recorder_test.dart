import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/performance_recorder.dart';
import 'package:moonfin/data/services/performance_store.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:server_core/server_core.dart' hide PackageInfo;
import 'package:playback_core/playback_core.dart';
import 'package:cached_network_image/cached_network_image.dart';

List<Map<String, dynamic>> events(String report) => report
    .substring(report.indexOf('EVENTS JSONL'))
    .split('\n')
    .where((line) => line.startsWith('{'))
    .map((line) => jsonDecode(line) as Map<String, dynamic>)
    .toList();

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
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'sample') return null;
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
    'old-player cleanup cannot finish launch before first picture',
    () async {
      await recorder.start();
      recorder.playTapped();
      recorder.bringup(
        const PlaybackBringupState(
          phase: PlaybackBringupPhase.stoppingPrevious,
        ),
      );
      recorder.bringup(const PlaybackBringupState.idle());
      recorder.bringup(
        const PlaybackBringupState(
          phase: PlaybackBringupPhase.resolving,
          sessionToken: 1,
        ),
      );
      final generation = recorder.mediaSourceOpened();
      recorder.mediaEvent('firstFrameRendered', {
        'diagnosticGeneration': generation,
        'nativeUs': 100,
      });
      recorder.mediaEvent('playing.changed', {
        'diagnosticGeneration': generation,
        'nativeUs': 200,
        'isPlaying': true,
      });
      final rows = events((await recorder.report())!);
      final launch = rows.singleWhere(
        (e) => e['event'] == 'span.end' && e['name'] == 'play.launch',
      );
      expect(launch['outcome'], 'ok');
      expect(
        rows.any((e) => e['event'] == 'play.previous_session_stopped'),
        isTrue,
      );
      expect(
        rows.singleWhere(
          (e) => e['event'] == 'span.end' && e['name'] == 'play.tap_to_playing',
        )['outcome'],
        'ok',
      );
    },
  );

  test('seek milestones use native time in either callback order', () async {
    await recorder.start();
    final generation = recorder.mediaSourceOpened();
    void send(String name, int time, [Map<String, Object?> data = const {}]) =>
        recorder.mediaEvent(name, {
          'diagnosticGeneration': generation,
          'nativeUs': time,
          ...data,
        });
    send('position.discontinuity', 1000, {'seek': true, 'targetMs': 60000});
    send('playing.changed', 1500, {'isPlaying': true});
    send('firstFrameRendered', 1900);
    send(
      'firstFrameRendered',
      2000,
    ); // Duplicate callback must not inflate totals.
    send('position.discontinuity', 10000, {'seek': true, 'targetMs': 90000});
    send('firstFrameRendered', 11000);
    send('audio.advancing', 11500);
    send('playing.changed', 12000, {'isPlaying': true});
    final rows = events((await recorder.report())!);
    expect(
      rows
          .where((e) => e['event'] == 'media.seek.first_frame')
          .map((e) => e['durationUs']),
      [900, 1000],
    );
    expect(
      rows
          .where((e) => e['event'] == 'media.seek.playing')
          .map((e) => e['durationUs']),
      [500, 2000],
    );
    expect(
      rows.singleWhere(
        (e) => e['event'] == 'media.seek.audio_advancing',
      )['durationUs'],
      1500,
    );
  });

  test(
    'rapid and paused seeks retain incomplete outcomes separately',
    () async {
      await recorder.start();
      final generation = recorder.mediaSourceOpened();
      for (final time in [1000, 2000]) {
        recorder.mediaEvent('position.discontinuity', {
          'diagnosticGeneration': generation,
          'nativeUs': time,
          'seek': true,
        });
      }
      recorder.mediaEvent('state', {
        'diagnosticGeneration': generation,
        'nativeUs': 2100,
        'isBuffering': true,
        'playWhenReady': false,
      });
      recorder.mediaEvent('firstFrameRendered', {
        'diagnosticGeneration': generation,
        'nativeUs': 3000,
      });
      recorder.mediaEvent('state', {
        'diagnosticGeneration': generation,
        'nativeUs': 3100,
        'isBuffering': false,
        'playWhenReady': false,
      });
      final rows = events((await recorder.report())!);
      expect(
        rows
            .where((e) => e['event'] == 'span.end' && e['name'] == 'play.seek')
            .map((e) => e['outcome']),
        ['superseded', 'recording_stopped'],
      );
      expect(
        rows.singleWhere(
          (e) => e['event'] == 'media.seek.first_frame',
        )['durationUs'],
        1000,
      );
      expect(
        rows.singleWhere(
          (e) => e['event'] == 'span.end' && e['name'] == 'media.buffering',
        )['kind'],
        'seek',
      );
      expect(rows.any((e) => e['event'] == 'media.seek.playing'), isFalse);
    },
  );

  test(
    'released source ignores stale state but keeps terminal transfers',
    () async {
      await recorder.start();
      final generation = recorder.mediaSourceOpened();
      recorder.mediaEvent('state', {
        'diagnosticGeneration': generation,
        'player': 7,
        'nativeUs': 1,
      });
      recorder.mediaEvent('player.released', {
        'diagnosticGeneration': generation,
        'player': 7,
        'nativeUs': 2,
      });
      recorder.mediaEvent('firstFrameRendered', {
        'diagnosticGeneration': generation,
        'player': 7,
        'nativeUs': 3,
      });
      recorder.mediaEvent('transfer.end', {
        'diagnosticGeneration': generation,
        'player': 7,
        'nativeUs': 4,
      });
      final rows = events((await recorder.report())!);
      expect(
        rows.where((v) => v['event'] == 'media.firstFrameRendered'),
        isEmpty,
      );
      expect(
        rows.where((v) => v['event'] == 'media.transfer.end'),
        hasLength(1),
      );
    },
  );

  test('old player and seek checkpoints cannot finish a newer seek', () async {
    await recorder.start();
    final generation = recorder.mediaSourceOpened();
    recorder.mediaEvent('position.discontinuity', {
      'diagnosticGeneration': generation,
      'player': 7,
      'seekSerial': 2,
      'nativeUs': 100,
      'seek': true,
    });
    recorder.mediaEvent('firstFrameRendered', {
      'diagnosticGeneration': generation,
      'player': 8,
      'seekSerial': 2,
      'nativeUs': 200,
    });
    recorder.mediaEvent('audio.advancing', {
      'diagnosticGeneration': generation,
      'player': 7,
      'seekSerial': 1,
      'nativeUs': 300,
    });
    final rows = events((await recorder.report())!);
    expect(rows.where((v) => v['event'] == 'media.seek.first_frame'), isEmpty);
    expect(
      rows.where((v) => v['event'] == 'media.seek.audio_advancing'),
      isEmpty,
    );
  });

  test(
    'stop during native configuration cannot reattach recorder hooks',
    () async {
      final configured = Completer<void>();
      final reply = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'configure' &&
                call.arguments['enabled'] == true) {
              configured.complete();
              await reply.future;
            }
            return null;
          });
      final starting = recorder.start();
      await configured.future;
      await recorder.stop();
      reply.complete();
      await starting;
      expect(recorder.recording, isFalse);
      expect(PerformanceTrace.enabled, isFalse);
      expect(CachedNetworkImage.performanceObserver, isNull);
    },
  );

  test('artwork repeats deduplicate within a visit and detach on stop', () async {
    await recorder.start();
    void image(String phase) => CachedNetworkImage.performanceObserver!(
      phase,
      'https://private.example/Items/private-id/Images/Primary?api_key=secret',
      320,
      null,
    );
    image('requested');
    image('requested');
    image('ready');
    image('painted_in_viewport');
    image('painted_in_viewport');
    PerformanceTrace.event('navigation.changed');
    image('requested');
    final report = (await recorder.report())!;
    final rows = events(report);
    expect(
      rows.where(
        (e) => e['event'] == 'span.begin' && e['name'] == 'artwork.widget.wait',
      ),
      hasLength(2),
    );
    expect(
      rows.where((e) => e['event'] == 'artwork.viewport.paint'),
      hasLength(1),
    );
    expect(report, isNot(contains('private.example')));
    expect(report, isNot(contains('private-id')));
    expect(report, isNot(contains('secret')));
    expect(CachedNetworkImage.performanceObserver, isNull);
  });

  test(
    'a new recording waits for native shutdown and final journal write',
    () async {
      await recorder.start();
      final requested = Completer<void>();
      final release = Completer<void>();
      var blocked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'configure' &&
                call.arguments['enabled'] == false &&
                !blocked) {
              blocked = true;
              requested.complete();
              await release.future;
            }
            return call.method == 'sample'
                ? <String, Object?>{'pssKiB': 100}
                : null;
          });
      final stopping = recorder.stop();
      await requested.future;
      final starting = recorder.start();
      expect(recorder.recording, isFalse);
      release.complete();
      await Future.wait([stopping, starting]);
      expect(recorder.recording, isTrue);
      final rows = events((await recorder.report())!);
      expect(rows.where((e) => e['event'] == 'recording.start'), hasLength(1));
      expect(rows.where((e) => e['event'] == 'recording.stop'), hasLength(1));
    },
  );

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
