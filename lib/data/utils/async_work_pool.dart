import 'dart:async';

/// Admission for optional metadata work. Obsolete owners are checked again
/// before dispatch. Aging prevents a busy foreground from starving older work.
class AsyncWorkPool {
  AsyncWorkPool(this.limit);
  final int limit;
  int running = 0;
  final List<_Work> _waiting = [];
  int get pending => _waiting.length;

  Future<T?> run<T>(
    Future<T> Function() body, {
    required bool Function() isCurrent,
    int Function()? priority,
  }) {
    final result = Completer<T?>();
    _waiting.add(
      _Work(() async {
        if (!isCurrent()) {
          result.complete(null);
          return;
        }
        try {
          result.complete(await body());
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      }, priority ?? () => 1),
    );
    _drain();
    return result.future;
  }

  void _drain() {
    while (running < limit && _waiting.isNotEmpty) {
      final now = DateTime.now();
      final expired = _waiting.indexWhere(
        (w) => now.difference(w.at).inSeconds >= 5,
      );
      var index = expired;
      if (index < 0) {
        index = 0;
        for (var i = 1; i < _waiting.length; i++) {
          if (_waiting[i].priority() < _waiting[index].priority()) index = i;
        }
      }
      final work = _waiting.removeAt(index);
      running++;
      unawaited(
        work.run().whenComplete(() {
          running--;
          _drain();
        }),
      );
    }
  }
}

class _Work {
  _Work(this.run, this.priority);
  final Future<void> Function() run;
  final int Function() priority;
  final at = DateTime.now();
}
