import 'dart:async';
import 'dart:ui' show FrameTiming, FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart' hide PackageInfo;

import '../../util/artwork_timing.dart';

import 'performance_recording.dart';
import 'performance_store.dart';

class PerformanceRecorder extends ChangeNotifier with WidgetsBindingObserver {
  PerformanceRecorder._() : _store = PerformanceStore();
  @visibleForTesting
  PerformanceRecorder.forTesting(PerformanceStore store) : _store = store;
  static final instance = PerformanceRecorder._();
  static const _native = MethodChannel('moonfin/performance');
  final PerformanceStore _store;
  PerformanceRecording? _recording;
  PerformanceSink? _sink;
  Timer? _sampleTimer, _heartbeat, _limit;
  Future<void>? _write;
  bool _sampling = false, _foreground = true, _busy = false;
  bool _storageFailed = false;
  bool recording = false, hasReport = false, showOverlay = true;
  String status = 'Record a session to investigate slow actions.';
  String screen = 'unknown';
  double? cpuPercent, memoryMiB;
  int _generation = 0, _ticks = 0, _lastHeartbeat = 0;
  int? _cpuMs, _nativeMs;
  final List<int> _builds = [], _rasters = [];
  int _frameCount = 0, _overBudget = 0, _frameMax = 0;
  int _frameOmitted = 0;
  final Map<Object, int> _identities = {};
  int _identity = 0;
  PerformanceSpan? _launch, _source;
  PerformanceSpan? _phase, _mainTitle, _prerollViewing;
  bool _isPreroll = false;
  int _sourceGeneration = 0;
  int? _sourceSession;
  bool _lastBuffering = false;
  PerformanceSpan? _buffering;
  Map<String, Object?>? _mediaState;

  bool get busy => _busy;
  int get elapsedSeconds =>
      (_recording?.clock.elapsedMilliseconds ?? 0) ~/ 1000;
  int get markerCount => _recording?.markers ?? 0;

  Future<void> initialize() async {
    if (recording || _busy) return;
    try {
      hasReport = await _store.exists();
    } catch (_) {
      /* optional */
    }
    notifyListeners();
  }

  int identity(Object? value) {
    if (!recording || value == null) return 0;
    if (_identities.containsKey(value)) return _identities[value]!;
    if (_identities.length >= 2048) return 0;
    return _identities[value] = ++_identity;
  }

  Future<void> start() async {
    if (recording || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      if (_write != null) await _write;
      await _store.start();
      final generation = ++_generation;
      _recording = PerformanceRecording();
      PerformanceTrace.resetAliases();
      _identities.clear();
      _identity = 0;
      _launch = null;
      _source = null;
      _buffering = null;
      _phase = null;
      _mainTitle = null;
      _prerollViewing = null;
      _sourceSession = null;
      _lastBuffering = false;
      _cpuMs = null;
      _nativeMs = null;
      _ticks = 0;
      _storageFailed = false;
      _mediaState = null;
      cpuPercent = null;
      memoryMiB = null;
      _builds.clear();
      _rasters.clear();
      _frameCount = 0;
      _overBudget = 0;
      _frameMax = 0;
      _frameOmitted = 0;
      recording = true;
      hasReport = true;
      _foreground =
          WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      _sink = (name, data) {
        if (recording && generation == _generation) _accept(name, data);
      };
      PerformanceTrace.sink = _sink;
      WidgetsBinding.instance.addObserver(this);
      SchedulerBinding.instance.addTimingsCallback(_frames);
      _accept('recording.start', {
        'build': const String.fromEnvironment(
          'MOONFIN_GIT_SHA',
          defaultValue: 'unknown',
        ),
        'mode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
        'screen': screen,
        'maxMinutes': 30,
      });
      try {
        final info = await PackageInfo.fromPlatform();
        if (generation == _generation && recording) {
          _accept('app.version', {
            'version': '${info.version}+${info.buildNumber}',
          });
        }
      } catch (_) {
        /* platform metadata unavailable in tests */
      }
      _lastHeartbeat = _recording!.clock.elapsedMicroseconds;
      _heartbeat = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final now = _recording!.clock.elapsedMicroseconds;
        final delay = now - _lastHeartbeat - 250000;
        _lastHeartbeat = now;
        if (_foreground && delay > 100000) {
          _accept('ui.heartbeat.delayed', {
            'durationUs': delay,
            'screen': screen,
          });
        }
      });
      _sampleTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_sample()),
      );
      _limit = Timer(
        const Duration(minutes: 30),
        () => unawaited(stop(reason: 'time_limit')),
      );
      status =
          'Recording. Use the app normally; mark anything that feels slow.';
      await _sample();
      await _flush();
    } catch (_) {
      status = 'Could not start recording. Check available app storage.';
      await stop(reason: 'storage_error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _accept(String name, Map<String, Object?> data) {
    _recording?.add(name, {'screen': screen, ...data});
    if (name.endsWith('.data.ready')) {
      final generation = _generation;
      final at = _recording!.clock.elapsedMicroseconds;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (recording && generation == _generation) {
          _recording?.add('ui.frame_after_data', {
            'name': name,
            'durationUs': _recording!.clock.elapsedMicroseconds - at,
            'screen': screen,
          });
        }
      });
    }
  }

  void marker() {
    if (!recording) return;
    _accept('user.marker', {'marker': markerCount + 1});
    status =
        'Marked moment ${markerCount}. Keep using the app or stop to send.';
    unawaited(_flush());
    notifyListeners();
  }

  void overlay(bool value) {
    showOverlay = value;
    notifyListeners();
  }

  double get _refreshRate {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final rate = views.isEmpty ? 60.0 : views.first.display.refreshRate;
    return rate > 0 ? rate : 60;
  }

  void _frames(List<FrameTiming> timings) {
    if (!recording || !_foreground) return;
    final budget = 1000000 / _refreshRate;
    for (final frame in timings) {
      final build = frame.buildDuration.inMicroseconds;
      final raster = frame.rasterDuration.inMicroseconds;
      _frameCount++;
      if (build > budget || raster > budget) _overBudget++;
      if (frame.totalSpan.inMicroseconds > _frameMax)
        _frameMax = frame.totalSpan.inMicroseconds;
      if (_builds.length < 512) {
        _builds.add(build);
        _rasters.add(raster);
      } else {
        _frameOmitted++;
      }
      if (build > 100000 || raster > 100000) {
        _accept('ui.slow_frame', {
          'buildUs': build,
          'rasterUs': raster,
          'totalUs': frame.totalSpan.inMicroseconds,
          'frameTimestampUs': frame.timestampInMicroseconds(
            FramePhase.buildStart,
          ),
        });
      }
    }
  }

  void _flushFrames() {
    if (_frameCount == 0) return;
    _builds.sort();
    _rasters.sort();
    _accept('ui.frames', {
      'frames': _frameCount,
      'overBudget': _overBudget,
      'refreshHz': _refreshRate,
      'buildP95Us': _builds[((_builds.length - 1) * .95).round()],
      'rasterP95Us': _rasters[((_rasters.length - 1) * .95).round()],
      'maxTotalUs': _frameMax,
      'omittedSamples': _frameOmitted,
    });
    _builds.clear();
    _rasters.clear();
    _frameCount = 0;
    _overBudget = 0;
    _frameMax = 0;
    _frameOmitted = 0;
  }

  Future<void> _sample() async {
    if (!recording || _sampling) return;
    _sampling = true;
    final generation = _generation;
    try {
      _ticks++;
      _flushFrames();
      if (_foreground || _sourceSession != null) {
        if (_mediaState != null) _accept('media.state', _mediaState!);
        final cache = PaintingBinding.instance.imageCache;
        _accept('cache.images', {
          'entries': cache.currentSize,
          'bytes': cache.currentSizeBytes,
          'live': cache.liveImageCount,
          'pending': cache.pendingImageCount,
        });
        if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) {
          final at = _recording!.clock.elapsedMicroseconds;
          final values = await _native
              .invokeMapMethod<String, dynamic>('sample', {
                'memory': _ticks == 1 || _ticks % 10 == 0,
              })
              .timeout(const Duration(seconds: 3));
          if (!recording || generation != _generation) return;
          final cpu = values?['cpuTimeMs'] as int?;
          final time = values?['elapsedRealtimeMs'] as int?;
          if (cpu != null &&
              time != null &&
              _cpuMs != null &&
              _nativeMs != null &&
              time > _nativeMs!) {
            cpuPercent = 100 * (cpu - _cpuMs!) / (time - _nativeMs!);
          }
          _cpuMs = cpu;
          _nativeMs = time;
          if (values?['pssKiB'] is num)
            memoryMiB = (values!['pssKiB'] as num) / 1024;
          _accept('resources.sample', {
            ...?values,
            'cpuOneCorePercent': cpuPercent,
            'bridgeRoundTripUs': _recording!.clock.elapsedMicroseconds - at,
          });
        }
      }
      if (_ticks % 5 == 0) await _flush();
    } catch (e) {
      if (recording && generation == _generation) {
        _accept('resources.unavailable', {'kind': e.runtimeType.toString()});
      }
    } finally {
      _sampling = false;
      if (recording && generation == _generation) notifyListeners();
    }
  }

  Future<void> _flush({bool complete = false}) async {
    final model = _recording;
    if (model == null) return;
    final previous = _write ?? Future<void>.value();
    final task = previous.then((_) async {
      final batch = model.drain();
      final summary = model.summary(complete: complete);
      try {
        final fits = await _store.append(batch, summary);
        if (!fits) {
          model.dropped += batch.length;
          if (recording) unawaited(stop(reason: 'size_limit'));
        }
      } catch (_) {
        _storageFailed = true;
        status = 'Storage write failed. Copy or send the available report before closing.';
        // Report missing events explicitly if storage is unavailable.
        for (final _ in batch) {
          model.dropped++;
        }
      }
    });
    _write = task;
    await task;
    if (identical(_write, task)) _write = null;
  }

  Future<void> stop({String reason = 'user'}) async {
    if (!recording) {
      if (_write != null) await _write;
      return;
    }
    _flushFrames();
    _launch?.end(outcome: 'recording_stopped');
    ArtworkTimings.flushNow();
    _source?.end(outcome: 'recording_stopped');
    _buffering?.end(outcome: 'recording_stopped');
    _phase?.end(outcome: 'recording_stopped');
    _mainTitle?.end(outcome: 'recording_stopped');
    _prerollViewing?.end(outcome: 'recording_stopped');
    _accept('recording.stop', {'reason': reason});
    recording = false;
    if (identical(PerformanceTrace.sink, _sink)) PerformanceTrace.sink = null;
    _sampleTimer?.cancel();
    _heartbeat?.cancel();
    _limit?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_frames);
    WidgetsBinding.instance.removeObserver(this);
    _recording?.clock.stop();
    _identities.clear();
    await _flush(complete: true);
    status = _storageFailed
        ? 'Some events could not be saved. Send the available report before closing.'
        : 'Recording saved. Send the performance report to your server.';
    notifyListeners();
  }

  Future<String?> report() async {
    if (recording) await stop();
    if (_write != null) await _write;
    String? saved;
    try {
      saved = await _store.read();
    } catch (_) {
      /* summary is still available */
    }
    final model = _recording;
    if (model == null) return saved;
    final journal = saved?.indexOf('EVENTS JSONL') ?? -1;
    return '${model.summary(complete: !recording)}\n'
        '${journal < 0 ? "Event journal unavailable" : saved!.substring(journal)}';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _cpuMs = null;
    _nativeMs = null;
    _lastHeartbeat = _recording?.clock.elapsedMicroseconds ?? 0;
    _accept('app.lifecycle', {'state': state.name});
    if (!_foreground) unawaited(_flush());
  }

  PerformanceSpan? playTapped() {
    if (!recording) return null;
    _launch?.end(outcome: 'superseded');
    _mainTitle?.end(outcome: 'superseded');
    _launch = PerformanceTrace.begin('play.launch');
    _mainTitle = PerformanceTrace.begin('play.main_title_including_prerolls');
    return _launch;
  }

  void bringup(PlaybackBringupState state, {bool isPreroll = false}) {
    if (!recording) return;
    _isPreroll = isPreroll;
    _phase?.end();
    _phase = null;
    if (!['ready', 'idle', 'failed'].contains(state.phase.name)) {
      _phase = PerformanceTrace.begin('play.phase.${state.phase.name}', {
        'isPreroll': isPreroll,
      });
    }
    if (state.phase == PlaybackBringupPhase.resolving && !isPreroll) {
      _prerollViewing?.end();
      _prerollViewing = null;
    }
    if (state.phase == PlaybackBringupPhase.resolving &&
        state.sessionToken != _sourceSession) {
      _source?.end(outcome: 'superseded');
      _sourceSession = state.sessionToken;
      _source = PerformanceTrace.begin('play.source', {
        'sourceId': identity(state.itemId),
      });
    }
    PerformanceTrace.event('play.phase', {
      'phase': state.phase.name,
      'launch': _launch?.id,
      'span': _source?.id,
      'backend': state.backend,
      'playMethod': state.playMethod,
      'sourceId': identity(state.itemId),
      'isPreroll': isPreroll,
    });
    if (state.phase == PlaybackBringupPhase.failed ||
        state.phase == PlaybackBringupPhase.idle) {
      _launch?.end(outcome: state.phase.name);
      _launch = null;
      _source?.end(outcome: state.phase.name);
      _source = null;
      _buffering?.end(outcome: state.phase.name);
      _buffering = null;
      _sourceSession = null;
      _mediaState = null;
      _mainTitle?.end(outcome: state.phase.name);
      _mainTitle = null;
      _prerollViewing?.end(outcome: state.phase.name);
      _prerollViewing = null;
    }
  }

  int mediaSourceOpened() {
    _sourceGeneration++;
    _mediaState = null;
    _buffering?.end(outcome: 'source_changed');
    _buffering = null;
    _lastBuffering = false;
    if (recording)
      PerformanceTrace.event('media.source_open', {
        'generation': _sourceGeneration,
        'launch': _launch?.id,
        'span': _source?.id,
      });
    return recording ? _sourceGeneration : 0;
  }

  void mediaEvent(String event, Map<dynamic, dynamic> map) {
    if (!recording) return;
    final generation = map['diagnosticGeneration'];
    if (generation == null ||
        generation == 0 ||
        generation != _sourceGeneration)
      return;
    if (event == 'state') {
      buffering(map['isBuffering'] == true);
      _mediaState = {
        'generation': generation,
        for (final key in [
          'nativeUs',
          'positionMs',
          'bufferedMs',
          'isPlaying',
          'isBuffering',
          'performanceBytes',
          'performanceLoads',
        ])
          if (map.containsKey(key)) key: map[key],
      };
      return;
    }
    const names = {
      'firstFrameRendered',
      'droppedFrames',
      'audioUnderrun',
      'videoDecoderInit',
      'audioDecoderInit',
      'performanceLoad',
      'performanceFormat',
      'performanceLoadStart',
      'performanceLoadError',
      'performanceMarker',
    };
    if (!names.contains(event)) return;
    PerformanceTrace.event('media.$event', {
      'launch': _launch?.id,
      'span': _source?.id,
      'generation': generation,
      'isPreroll': _isPreroll,
      for (final key in [
        'nativeUs',
        'positionMs',
        'count',
        'elapsedMs',
        'bufferSizeMs',
        'decoder',
        'initializationDurationMs',
        'durationMs',
        'bytes',
        'performanceBytes',
        'loadId',
        'kind',
        'width',
        'height',
        'bitrate',
        'frameRate',
        'codec',
        'outcome',
      ])
        if (map.containsKey(key)) key: map[key],
    });
    if (event == 'firstFrameRendered') {
      _launch?.end(data: {'backend': 'media3', 'generation': generation});
      _launch = null;
      _source?.end(data: {'backend': 'media3', 'generation': generation});
      _source = null;
      if (_isPreroll) {
        _prerollViewing?.end();
        _prerollViewing = PerformanceTrace.begin('play.preroll_viewing');
      } else {
        _mainTitle?.end(data: {'backend': 'media3', 'generation': generation});
        _mainTitle = null;
      }
    }
    if (event == 'performanceMarker') marker();
  }

  void buffering(bool value) {
    if (!recording || value == _lastBuffering) return;
    _lastBuffering = value;
    if (value)
      _buffering = PerformanceTrace.begin('media.buffering', {
        'generation': _sourceGeneration,
      });
    else {
      _buffering?.end();
      _buffering = null;
    }
  }
}

class PerformanceRouteObserver extends NavigatorObserver {
  void _changed(Route<dynamic>? route, String reason) {
    final recorder = PerformanceRecorder.instance;
    final raw = route?.settings.name;
    // Only static route segments survive; identifiers/search parameters never do.
    recorder.screen = PerformanceInterceptor.endpoint(
      Uri.tryParse(raw ?? '/unknown') ?? Uri(),
    );
    if (!recorder.recording) return;
    PerformanceTrace.event('navigation.changed', {
      'reason': reason,
      'screen': recorder.screen,
    });
    final span = PerformanceTrace.begin('navigation.frame');
    WidgetsBinding.instance.addPostFrameCallback((_) => span?.end());
  }

  @override
  void didPush(Route route, Route? previousRoute) => _changed(route, 'push');
  @override
  void didPop(Route route, Route? previousRoute) =>
      _changed(previousRoute, 'pop');
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) =>
      _changed(newRoute, 'replace');
}
