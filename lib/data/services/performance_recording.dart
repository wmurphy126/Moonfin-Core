import 'dart:collection';
import 'dart:convert';

/// Bounded, structured diagnostic data. No response bodies or free-form logs.
class PerformanceRecording {
  PerformanceRecording({this.maxBytes = 2 * 1024 * 1024});
  final int maxBytes;
  final clock = Stopwatch()..start();
  final started = DateTime.now().toUtc();
  final Queue<String> _pending = Queue();
  final Map<String, _Aggregate> _durations = {};
  final Map<int, String> _active = {};
  final Map<int, Map<String, Object?>> _spanContext = {};
  final Map<int, (String, int)> _requestCounts = {};
  final Map<String, int> _outcomes = {};
  final List<Map<String, Object?>> _markers = [];
  final Map<int, String> _requests = {};
  final Map<String, int> _requestPeaks = {};
  final Map<String, List<double>> _resources = {};
  final Map<int, String> _ownedResources = {};
  final Map<String, int> _counts = {};
  final List<Map<String, Object?>> _slowest = [];
  int _bytes = 0;
  int dropped = 0;
  int events = 0;
  int markers = 0;

  static const _strings = {
    'name',
    'phase',
    'backend',
    'playMethod',
    'state',
    'outcome',
    'method',
    'endpoint',
    'screen',
    'decoder',
    'codec',
    'build',
    'version',
    'model',
    'os',
    'network',
    'reason',
    'mode',
    'metric',
    'source',
    'kind',
    'caller',
    'idKind',
    'row',
  };
  static final _safe = RegExp(r'^[a-zA-Z0-9_./:+ -]{1,160}$');

  static Map<String, Object?> sanitize(Map<String, Object?> data) {
    final out = <String, Object?>{};
    for (final entry in data.entries.take(96)) {
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$').hasMatch(entry.key))
        continue;
      if (RegExp(
        r'token|auth|cookie|password|url|title|query|path|deviceId|userId|itemId',
        caseSensitive: false,
      ).hasMatch(entry.key))
        continue;
      final value = entry.value;
      if (value == null || value is bool || (value is num && value.isFinite)) {
        out[entry.key] = value;
      } else if (value is String &&
          _strings.contains(entry.key) &&
          _safe.hasMatch(value) &&
          !value.contains('://')) {
        out[entry.key] = value;
      }
    }
    return out;
  }

  void add(String event, Map<String, Object?> attributes) {
    if (!_safe.hasMatch(event)) return;
    final data = sanitize(attributes);
    if (event == 'span.end') {
      final context = _spanContext.remove(data['id']);
      if (context != null) {
        for (final entry in context.entries) {
          data.putIfAbsent(entry.key, () => entry.value);
        }
      }
    }
    final record = <String, Object?>{
      'tUs': clock.elapsedMicroseconds,
      'event': event,
      ...data,
    };
    final name = data['name'] as String? ?? event;
    final countKey = _counts.containsKey(name) || _counts.length < 128
        ? name
        : 'other';
    _counts[countKey] = (_counts[countKey] ?? 0) + 1;
    if (event == 'span.begin' && data['id'] is int && _active.length < 512) {
      _active[data['id'] as int] = name;
      _spanContext[data['id'] as int] = {
        for (final key in [
          'caller',
          'idKind',
          'seerrOnly',
          'row',
          'kind',
          'requestAlias',
          'visit',
        ])
          if (data.containsKey(key)) key: data[key],
      };
      if (name == 'http.request') {
        final endpoint = data['endpoint'] as String? ?? 'unknown';
        final alias = data['requestAlias'];
        if (alias is int &&
            alias != 0 &&
            (_requestCounts.length < 4096 ||
                _requestCounts.containsKey(alias))) {
          _requestCounts[alias] = (
            endpoint,
            (_requestCounts[alias]?.$2 ?? 0) + 1,
          );
        }
        _requests[data['id'] as int] = endpoint;
        final active = _requests.values
            .where((value) => value == endpoint)
            .length;
        if ((_requestPeaks.containsKey(endpoint) ||
                _requestPeaks.length < 128) &&
            (_requestPeaks[endpoint] ?? 0) < active)
          _requestPeaks[endpoint] = active;
      }
    }
    if (event == 'span.end') {
      _active.remove(data['id']);
      _requests.remove(data['id']);
      final key = '$name ${data['outcome'] ?? 'unknown'}';
      if (_outcomes.length < 256 || _outcomes.containsKey(key)) {
        _outcomes[key] = (_outcomes[key] ?? 0) + 1;
      }
    }
    if (event == 'resources.sample') {
      for (final key in [
        'cpuOneCorePercent',
        'pssKiB',
        'rssKiB',
        'javaUsedBytes',
        'nativeAllocatedBytes',
        'fdCount',
        'threads',
        'graphicsKiB',
        'privateOtherKiB',
        'javaCommittedBytes',
        'javaLimitBytes',
        'artGcCountDelta',
        'artGcTimeMsDelta',
        'artBlockingGcCountDelta',
        'artBlockingGcTimeMsDelta',
        'artBytesAllocatedDelta',
        'artBytesFreedDelta',
        'sampleCostUs',
        'bridgeRoundTripUs',
        'mainHeartbeatMaxDelayMs',
      ]) {
        final value = data[key];
        if (value is! num) continue;
        final metrics = _resources.putIfAbsent(
          key,
          () => [value.toDouble(), value.toDouble(), value.toDouble()],
        );
        metrics[1] = value.toDouble();
        if (value > metrics[2]) metrics[2] = value.toDouble();
      }
    }
    if (event == 'user.marker') {
      markers++;
      if (_markers.length < 100)
        _markers.add({
          ...record,
          'activeSpans': _active.length,
          'activeRequests': _requests.length,
          'lastPssKiB': _resources['pssKiB']?[1],
          'lastCpuOneCorePercent': _resources['cpuOneCorePercent']?[1],
        });
    }
    if (event == 'resource.observed' &&
        data['resource'] is int &&
        _ownedResources.length < 512) {
      _ownedResources[data['resource'] as int] =
          data['kind'] as String? ?? 'unknown';
    }
    if (event == 'resource.disposed') _ownedResources.remove(data['resource']);
    final duration = data['durationUs'];
    if (duration is num) {
      var label = name == 'http.request'
          ? '$name ${data['method'] ?? ''} ${data['endpoint'] ?? ''}'
          : name;
      if (data['kind'] != null) label += ' ${data['kind']}';
      if (event == 'span.end' && data['outcome'] != 'ok') {
        label += ' [${data['outcome'] ?? 'unknown'}]';
      }
      final key = _durations.containsKey(label) || _durations.length < 128
          ? label
          : 'other';
      (_durations[key] ??= _Aggregate()).add(duration.toDouble());
      _slowest.add(record);
      _slowest.sort(
        (a, b) => (b['durationUs'] as num).compareTo(a['durationUs'] as num),
      );
      if (_slowest.length > 30) _slowest.removeLast();
    }
    final line = jsonEncode(record);
    // All accepted fields are ASCII; avoid a second UTF-8 allocation per event.
    if (line.length > maxBytes) {
      dropped++;
      return;
    }
    while (_bytes + line.length > maxBytes && _pending.isNotEmpty) {
      _bytes -= _pending.removeFirst().length;
      dropped++;
    }
    _pending.add(line);
    _bytes += line.length;
    events++;
  }

  List<String> drain() {
    final result = _pending.toList(growable: false);
    _pending.clear();
    _bytes = 0;
    return result;
  }

  String summary({required bool complete}) {
    final text = StringBuffer()
      ..writeln('Moonfin performance recording — schema 2')
      ..writeln('Started UTC: ${started.toIso8601String()}')
      ..writeln(
        'Duration: ${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} seconds',
      )
      ..writeln(
        'Complete: $complete; events: $events; dropped: $dropped; problem markers: $markers',
      )
      ..writeln(
        'No titles, queries, server addresses, tokens, persistent device IDs or response bodies are recorded.',
      )
      ..writeln(
        'CPU 100% = one occupied core. RSS/PSS overlap; do not add them.',
      )
      ..writeln(
        'ART GC counters cover Java/Kotlin, not the Dart heap. This recording does not contain heap snapshots or GPU utilization.',
      )
      ..writeln(
        'Memory growth is not proof of a leak. Compare repeated equivalent cycles after warmup.',
      )
      ..writeln(
        'Request time is client-observed; header wait includes connection/network/server work.',
      )
      ..writeln(
        'http.dispatched duration = client queue wait; http.headers duration = dispatch to headers; http.request also includes body/decoding except streamed responses.',
      )
      ..writeln(
        'Frame summaries describe Flutter UI; media frame drops are reported separately.',
      )
      ..writeln(
        'Frame-after-data is a paint checkpoint, not proof every row was visible.',
      )
      ..writeln(
        'play.launch ends at the first video frame, possibly an intro. main_title_including_prerolls includes intentional intro viewing; preroll_viewing is reported separately.',
      )
      ..writeln(
        'Native media events use nativeUs monotonic timestamps; tUs is Dart receipt time and includes bridge delay. Resource samples link the two clocks.',
      )
      ..writeln(
        'play.tap_to_playing is distinct from the first picture. media.seek timings start at the native accepted-position change, not the finger gesture.',
      )
      ..writeln(
        'media.seek_command measures Dart command dispatch/acknowledgment. position.advancing requires 50ms of position movement while playing, observed on the existing 250ms state ticker. prepare.returned measures synchronous setup, not decoder readiness.',
      )
      ..writeln(
        'networkBytes counts live network reads including canceled loads. Completed-load bytes are separate. Transfer end is not necessarily successful completion; source changes reset counters.',
      )
      ..writeln(
        'Artwork ready uses the existing image builder; viewport paint is a bounds-overlap estimate, not an occlusion test. Local-file images and non-CachedNetworkImage widgets are outside this coverage.',
      )
      ..writeln(
        'GC deltas are Java/ART collection work, not UI pause durations. Detailed memory is sampled every ten seconds and on markers when the sampler is free. Unknown or unavailable measurements are not zero.',
      )
      ..writeln(
        'Diagnostic overhead: sampleCostUs is worker collection cost; bridgeRoundTripUs includes platform scheduling; diagnostics.writer measures serialization and journal writes. Native and Dart heartbeat delays describe different threads. requestAtUs/replyAtUs bound clock alignment uncertainty.',
      )
      ..writeln(
        '\nDuration summary (ms; recent p95 uses at most 256 samples):',
      );
    for (final entry in _durations.entries) {
      text.writeln('${entry.key}: ${entry.value.describe()}');
    }
    text.writeln(
      '\nResource samples (first / last / peak; CPU is one-core percent):',
    );
    for (final entry in _resources.entries) {
      text.writeln(
        '${entry.key}: ${entry.value.map((v) => v.toStringAsFixed(1)).join(' / ')}',
      );
    }
    text.writeln(
      '\nPeak concurrent API requests by endpoint (includes queued work):',
    );
    for (final entry in _requestPeaks.entries) {
      text.writeln('${entry.key}: ${entry.value}');
    }
    text.writeln(
      '\nRepeated request aliases (same method/path/parameters, credentials excluded; repeats may be intentional):',
    );
    final repeated =
        _requestCounts.entries.where((e) => e.value.$2 > 1).toList()
          ..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    for (final entry in repeated.take(30)) {
      text.writeln(
        'request ${entry.key}: ${entry.value.$1} count=${entry.value.$2}',
      );
    }
    text.writeln(
      '\nOperation outcomes (incomplete/failed timings are kept separate):',
    );
    for (final entry in _outcomes.entries) {
      text.writeln('${entry.key}: ${entry.value}');
    }
    text.writeln('\nProblem markers and nearby sampled resource state:');
    for (final marker in _markers) {
      text.writeln(jsonEncode(marker));
    }
    text.writeln(
      '\nLongest operations (overlapping durations must not be summed):',
    );
    for (final row in _slowest) {
      text.writeln(jsonEncode(row));
    }
    text.writeln('\nUnfinished spans at checkpoint: ${_active.length}');
    text.writeln(
      'Observed view models without a disposal event: ${_ownedResources.length} (active screens and long-lived models may be intentional).',
    );
    for (final entry in _ownedResources.entries.take(40)) {
      text.writeln('resource ${entry.key}: ${entry.value}');
    }
    for (final entry in _active.entries.take(40)) {
      text.writeln('${entry.key}: ${entry.value}');
    }
    text.writeln('\nEvent counts (begin/end are separate events):');
    for (final entry in _counts.entries) {
      text.writeln('${entry.key}: ${entry.value}');
    }
    return text.toString();
  }
}

class _Aggregate {
  int count = 0;
  double sum = 0, max = 0;
  final Queue<double> recent = Queue();
  void add(double value) {
    count++;
    sum += value;
    if (value > max) max = value;
    recent.add(value);
    if (recent.length > 256) recent.removeFirst();
  }

  String describe() {
    final sorted = recent.toList()..sort();
    final p95 = sorted[((sorted.length - 1) * .95).round()];
    return 'n=$count mean=${(sum / count / 1000).toStringAsFixed(1)} recentP95=${(p95 / 1000).toStringAsFixed(1)} max=${(max / 1000).toStringAsFixed(1)}';
  }
}
