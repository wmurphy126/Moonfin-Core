import 'dart:async';

typedef PerformanceSink =
    void Function(String event, Map<String, Object?> data);

/// Optional structured diagnostics. Never changes request or playback policy.
/// The sink must not throw; diagnostics failures cannot fail an operation.
class PerformanceTrace {
  static PerformanceSink? sink;
  static final _contextKey = Object();
  static int _sequence = 0;
  static final Map<String, int> _aliases = {};
  static Expando<int> _resources = Expando<int>();
  static int resource(Object object) {
    if (!enabled) return 0;
    return _resources[object] ??= ++_sequence;
  }

  static void observed(Object object, String kind) =>
      event('resource.observed', {'resource': resource(object), 'kind': kind});
  static void disposed(Object object, String kind) =>
      event('resource.disposed', {'resource': resource(object), 'kind': kind});
  static void resetAliases() {
    _aliases.clear();
    _resources = Expando<int>();
  }

  static int alias(String value) {
    if (_aliases.containsKey(value)) return _aliases[value]!;
    if (_aliases.length >= 256) return 0;
    return _aliases[value] = _aliases.length + 1;
  }

  static int get current => Zone.current[_contextKey] as int? ?? 0;
  static bool get enabled => sink != null;

  static void event(String name, [Map<String, Object?> data = const {}]) {
    final target = sink;
    if (target == null) return;
    try {
      target(name, {'parent': current, ...data});
    } catch (_) {
      // Telemetry is best effort, including during shutdown and low memory.
    }
  }

  static PerformanceSpan? begin(
    String name, [
    Map<String, Object?> data = const {},
  ]) {
    final target = sink;
    if (target == null) return null;
    final span = PerformanceSpan._(++_sequence, name, target);
    event('span.begin', {'id': span.id, 'name': name, ...data});
    return span;
  }

  static Future<T> measure<T>(
    String name,
    Future<T> Function() body, {
    Map<String, Object?> data = const {},
  }) {
    final span = begin(name, data);
    if (span == null) return body();
    return runZoned(() async {
      try {
        final result = await body();
        span.end();
        return result;
      } catch (_) {
        span.end(outcome: 'error');
        rethrow;
      }
    }, zoneValues: {_contextKey: span.id});
  }
}

class PerformanceSpan {
  PerformanceSpan._(this.id, this.name, this._owner);
  final int id;
  final String name;
  final PerformanceSink _owner;
  final Stopwatch _clock = Stopwatch()..start();
  bool _ended = false;
  int get elapsedUs => _clock.elapsedMicroseconds;

  void mark(String stage, [Map<String, Object?> data = const {}]) {
    if (_ended || !identical(PerformanceTrace.sink, _owner)) return;
    PerformanceTrace.event(stage, {
      'span': id,
      'elapsedUs': elapsedUs,
      ...data,
    });
  }

  void end({String outcome = 'ok', Map<String, Object?> data = const {}}) {
    if (_ended) return;
    _ended = true;
    _clock.stop();
    if (!identical(PerformanceTrace.sink, _owner)) return;
    PerformanceTrace.event('span.end', {
      'id': id,
      'name': name,
      'durationUs': elapsedUs,
      'outcome': outcome,
      ...data,
    });
  }
}
