import 'dart:collection';

import 'package:clock/clock.dart';

/// Small LRU for derived metadata. Owners must clear it on account or source
/// changes; TTL also bounds staleness when a server sends no invalidation event.
class ExpiringCache<K, V> {
  ExpiringCache({required this.capacity, required this.ttl});
  final int capacity;
  final Duration ttl;
  final _entries = LinkedHashMap<K, (DateTime, V)>();
  int hits = 0, misses = 0, evictions = 0;
  int get length => _entries.length;
  V? operator [](K key) {
    final entry = _entries.remove(key);
    if (entry == null || clock.now().difference(entry.$1) >= ttl) {
      misses++;
      return null;
    }
    hits++;
    _entries[key] = entry;
    return entry.$2;
  }

  void operator []=(K key, V value) {
    _entries.remove(key);
    _entries[key] = (clock.now(), value);
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
      evictions++;
    }
  }

  void clear() => _entries.clear();
}
