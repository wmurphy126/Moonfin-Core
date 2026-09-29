import 'dart:async';
import 'dart:ui' show FrameTiming, FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
  Future<void>? _stopping;
  bool _sampling = false, _foreground = true, _busy = false;
  bool _observersAttached = false;
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
  Map<String, Object?>? _decoderCounters;
  PerformanceSpan? _firstPlaying, _seek;
  PlaybackBringupPhase? _previousPhase;
  int? _seekNativeUs, _mediaStateReceivedUs, _networkSampleUs, _networkBytes;
  bool _seekFrameSeen = false, _seekPlayingSeen = false, _seekAudioSeen = false;
  bool _hadFrame = false;
  int? _seekId;
  String _bufferingKind = 'startup';
  int _visit = 0;
  final Map<int, PerformanceSpan> _artworkSpans = {};
  final Set<int> _artworkReady = {}, _artworkPainted = {};

  bool get busy => _busy || _stopping != null;
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
    if (_stopping != null) await _stopping;
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
      _firstPlaying = null;
      _seek = null;
      _seekNativeUs = null;
      _seekId = null;
      _previousPhase = null;
      _decoderCounters = null;
      _mediaStateReceivedUs = null;
      _networkSampleUs = null;
      _networkBytes = null;
      _hadFrame = false;
      _visit = 0;
      _artworkSpans.clear();
      _artworkReady.clear();
      _artworkPainted.clear();
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
      CachedNetworkImage.performanceObserver = _imageEvent;
      await _configureNative(true);
      if (!recording || generation != _generation) return;
      WidgetsBinding.instance.addObserver(this);
      SchedulerBinding.instance.addTimingsCallback(_frames);
      _observersAttached = true;

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
      if (!recording || generation != _generation) return;
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

  Future<void> _configureNative(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _native
          .invokeMethod<Object?>('configure', {'enabled': enabled})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      if (recording)
        _accept('diagnostics.native_configuration_unavailable', {});
    }
  }

  void _accept(String name, Map<String, Object?> data) {
    if (name == 'navigation.changed') {
      _visit++;
      for (final span in _artworkSpans.values) {
        span.end(outcome: 'navigation_changed');
      }
      _artworkSpans.clear();
      _artworkReady.clear();
      _artworkPainted.clear();
    }
    _recording?.add(name, {'screen': screen, ...data});
    if (name.endsWith('.data.ready')) {
      final generation = _generation;
      final visit = _visit;
      final originalScreen = screen;
      final at = _recording!.clock.elapsedMicroseconds;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (recording && generation == _generation && visit == _visit) {
          _recording?.add('ui.frame_after_data', {
            'name': name,
            'durationUs': _recording!.clock.elapsedMicroseconds - at,
            'screen': originalScreen,
            'visit': visit,
            'parent': data['parent'],
            'row': data['row'],
          });
        }
      });
    }
  }

  void _imageEvent(String stage, String key, int? width, int? height) {
    if (!recording) return;
    final uri = Uri.tryParse(key);
    if (uri == null || !uri.hasAuthority) return;
    final alias = PerformanceTrace.alias(
      'image:$_visit:${uri.origin}${uri.path}:$width:$height',
    );
    if (alias == 0) return;
    if (stage == 'requested') {
      if (_artworkSpans.containsKey(alias) ||
          _artworkReady.contains(alias) ||
          _artworkSpans.length >= 256 ||
          _artworkReady.length >= 1024)
        return;
      final span = PerformanceTrace.begin('artwork.widget.wait', {
        'image': alias,
        'imageSource': PerformanceTrace.alias('image:${uri.origin}${uri.path}'),
        'visit': _visit,
        'decodeWidth': width,
        'decodeHeight': height,
      });
      if (span != null) _artworkSpans[alias] = span;
    } else if (stage == 'ready' || stage == 'error') {
      final span = _artworkSpans.remove(alias);
      if (span == null) return;
      _artworkReady.add(alias);
      span.end(
        outcome: stage == 'error' ? 'error' : 'ok',
        data: {'image': alias},
      );
    } else if (stage == 'painted_in_viewport' &&
        _artworkPainted.length < 1024 &&
        _artworkPainted.add(alias)) {
      PerformanceTrace.event('artwork.viewport.paint', {
        'image': alias,
        'visit': _visit,
      });
    }
  }

  void marker() {
    if (!recording) return;
    _accept('user.marker', {'marker': markerCount + 1});
    status =
        'Marked moment ${markerCount}. Keep using the app or stop to send.';
    unawaited(_sample(detailed: true));
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

  Future<void> _sample({bool detailed = false}) async {
    if (!recording || _sampling) return;
    _sampling = true;
    final generation = _generation;
    try {
      _ticks++;
      _flushFrames();
      if (_foreground || _sourceSession != null) {
        final state = _mediaState;
        if (state != null) {
          final now = _recording!.clock.elapsedMicroseconds;
          final nativeUs = state['nativeUs'] as int?;
          final bytes = state['networkBytes'] as int?;
          _accept('media.state', {
            ...state,
            'stateAgeUs': now - (_mediaStateReceivedUs ?? now),
            if (nativeUs != null &&
                bytes != null &&
                _networkBytes != null &&
                _networkSampleUs != null &&
                nativeUs > _networkSampleUs! &&
                bytes >= _networkBytes!)
              'networkBitsPerSecond':
                  (bytes - _networkBytes!) *
                  8000000 /
                  (nativeUs - _networkSampleUs!),
          });
          _networkSampleUs = nativeUs;
          _networkBytes = bytes;
        }
        if (_decoderCounters != null)
          _accept('media.decoder.counters', _decoderCounters!);
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
                'memory': detailed || _ticks == 1 || _ticks % 10 == 0,
                'reset': _ticks == 1,
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
            'requestAtUs': at,
            'replyAtUs': _recording!.clock.elapsedMicroseconds,
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
      final cost = Stopwatch()..start();
      final batch = model.drain();
      final summary = model.summary(complete: complete);
      final serializationUs = cost.elapsedMicroseconds;
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
      if (recording && identical(model, _recording)) {
        _accept('diagnostics.writer', {
          'events': batch.length,
          'serializationUs': serializationUs,
          'durationUs': cost.elapsedMicroseconds,
        });
      }
    });
    _write = task;
    await task;
    if (identical(_write, task)) _write = null;
  }

  Future<void> stop({String reason = 'user'}) {
    final pending = _stopping;
    if (pending != null) return pending;
    final task = _stop(reason);
    _stopping = task;
    return task.whenComplete(() {
      if (identical(_stopping, task)) _stopping = null;
      notifyListeners();
    });
  }

  Future<void> _stop(String reason) async {
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
    _firstPlaying?.end(outcome: 'recording_stopped');
    _seek?.end(outcome: 'recording_stopped');
    for (final span in _artworkSpans.values) {
      span.end(outcome: 'recording_stopped');
    }
    _artworkSpans.clear();
    if (CachedNetworkImage.performanceObserver == _imageEvent) {
      CachedNetworkImage.performanceObserver = null;
    }
    _prerollViewing?.end(outcome: 'recording_stopped');
    _accept('recording.stop', {'reason': reason});
    recording = false;
    if (identical(PerformanceTrace.sink, _sink)) PerformanceTrace.sink = null;
    PerformanceTrace.resetAliases();
    _sampleTimer?.cancel();
    _heartbeat?.cancel();
    _limit?.cancel();
    if (_observersAttached) {
      SchedulerBinding.instance.removeTimingsCallback(_frames);
      WidgetsBinding.instance.removeObserver(this);
      _observersAttached = false;
    }
    await _configureNative(false);
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
    _firstPlaying?.end(outcome: 'superseded');
    _launch = PerformanceTrace.begin('play.launch');
    _mainTitle = PerformanceTrace.begin('play.main_title_including_prerolls');
    _firstPlaying = PerformanceTrace.begin('play.tap_to_playing');
    return _launch;
  }

  void bringup(PlaybackBringupState state, {bool isPreroll = false}) {
    if (!recording) return;
    _isPreroll = isPreroll;
    final previousPhase = _previousPhase;
    _previousPhase = state.phase;
    // stop() emits idle while a new launch is replacing the previous player.
    // This is an intermediate teardown, not cancellation of the new launch.
    if (state.phase == PlaybackBringupPhase.idle &&
        previousPhase == PlaybackBringupPhase.stoppingPrevious &&
        _launch != null) {
      PerformanceTrace.event('play.previous_session_stopped', {
        'launch': _launch!.id,
      });
      return;
    }
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
      _firstPlaying?.end(outcome: state.phase.name);
      _firstPlaying = null;
      _seek?.end(outcome: state.phase.name);
      _seek = null;
      _seekNativeUs = null;
      _seekId = null;
      _prerollViewing?.end(outcome: state.phase.name);
      _prerollViewing = null;
    }
  }

  int mediaSourceOpened() {
    _sourceGeneration++;
    _seek?.end(outcome: 'source_changed');
    _seek = null;
    _seekNativeUs = null;
    _seekId = null;
    _hadFrame = false;
    _decoderCounters = null;
    _networkBytes = null;
    _networkSampleUs = null;
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
      if (map['isBuffering'] == true && !_lastBuffering) {
        _bufferingKind = _seek != null
            ? 'seek'
            : !_hadFrame
            ? 'startup'
            : map['playWhenReady'] == false
            ? 'paused'
            : 'rebuffer';
      }
      buffering(map['isBuffering'] == true);
      _mediaStateReceivedUs = _recording!.clock.elapsedMicroseconds;
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
          'networkBytes',
          'activeTransfers',
          'endedTransfers',
          'omittedTransfers',
          'lastByteAgeUs',
          'firstByteNativeUs',
          'bufferAheadMs',
          'playWhenReady',
          'playbackStateCode',
          'suppressionReason',
          'isLoading',
          'seekable',
          'live',
        ])
          if (map.containsKey(key)) key: map[key],
      };
      return;
    }
    if (event == 'decoder.counters') {
      _decoderCounters = {
        for (final key in [
          'nativeUs',
          'rendered',
          'dropped',
          'skipped',
          'maxConsecutiveDropped',
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
      'performanceLoadCanceled',
      'performanceMarker',
      'position.discontinuity',
      'position.advancing',
      'seek.command',
      'playback.state',
      'playing.changed',
      'play_intent',
      'player.error',
      'audio.advancing',
      'source.config',
      'prepare.returned',
      'player.created',
      'audio.track_initialized',
      'audio.track_released',
      'bandwidth.estimate',
      'transfer.open',
      'transfer.headers',
      'transfer.first_byte',
      'transfer.end',
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
        'caller',
        'width',
        'height',
        'bitrate',
        'frameRate',
        'codec',
        'outcome',
        'transfer',
        'rangeStart',
        'requestedBytes',
        'durationUs',
        'status',
        'stateCode',
        'reasonCode',
        'errorCode',
        'fromMs',
        'targetMs',
        'seek',
        'adjustment',
        'playWhenReady',
        'isPlaying',
        'suppressionReason',
        'internalRecovery',
        'resumeMs',
        'heapLimitBytes',
        'playerCreateUs',
        'targetBufferBytes',
        'minBufferMs',
        'maxBufferMs',
        'startBufferMs',
        'rebufferMs',
        'lowRam',
        'sampleRate',
        'channels',
        'encoding',
        'offload',
        'bufferBytes',
        'bitrateEstimate',
      ])
        if (map.containsKey(key)) key: map[key],
    });
    if (event == 'position.discontinuity' && map['seek'] == true) {
      _seek?.end(outcome: 'superseded');
      _seekNativeUs = map['nativeUs'] as int?;
      _seekFrameSeen = false;
      _seekPlayingSeen = false;
      _seekAudioSeen = false;
      _seek = PerformanceTrace.begin('play.seek', {
        'fromMs': map['fromMs'],
        'targetMs': map['targetMs'],
        'generation': generation,
        'nativeUs': _seekNativeUs,
      });
      _seekId = _seek?.id;
    }
    if (event == 'playing.changed' && map['isPlaying'] == true) {
      _firstPlaying?.end(data: {'backend': 'media3', 'generation': generation});
      _firstPlaying = null;
      if (!_seekPlayingSeen) _seekCheckpoint('playing', map);
      _seekPlayingSeen = true;
      _seek?.end();
      _seek = null;
    }
    if (event == 'audio.advancing' && !_seekAudioSeen) {
      _seekCheckpoint('audio_advancing', map);
      _seekAudioSeen = true;
    }
    if (event == 'position.advancing')
      _seekCheckpoint('position_advancing', map);
    if (event == 'firstFrameRendered') {
      _hadFrame = true;
      if (!_seekFrameSeen) {
        _seekCheckpoint('first_frame', map);
        _seekFrameSeen = true;
      }
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

  void _seekCheckpoint(String stage, Map<dynamic, dynamic> map) {
    final nativeUs = map['nativeUs'];
    if (_seekId == null ||
        _seekNativeUs == null ||
        nativeUs is! int ||
        nativeUs < _seekNativeUs!)
      return;
    PerformanceTrace.event('media.seek.$stage', {
      'span': _seekId,
      'generation': _sourceGeneration,
      'durationUs': nativeUs - _seekNativeUs!,
      'nativeUs': nativeUs,
    });
  }

  void buffering(bool value) {
    if (!recording || value == _lastBuffering) return;
    _lastBuffering = value;
    if (value)
      _buffering = PerformanceTrace.begin('media.buffering', {
        'generation': _sourceGeneration,
        'kind': _bufferingKind,
      });
    else {
      _buffering?.end(data: {'kind': _bufferingKind});
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
