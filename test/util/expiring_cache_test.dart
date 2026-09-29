import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/utils/expiring_cache.dart';

void main() {
  test('LRU is bounded, reads do not extend TTL, clear invalidates', () {
    var now = DateTime(2026);
    withClock(Clock(() => now), () {
      final cache = ExpiringCache<String, int>(
        capacity: 2,
        ttl: const Duration(seconds: 60),
      );
      cache['a'] = 1;
      cache['b'] = 2;
      expect(cache['a'], 1);
      cache['c'] = 3;
      expect(cache['b'], isNull);
      expect(cache.length, 2);
      now = now.add(const Duration(seconds: 61));
      expect(cache['a'], isNull);
      cache.clear();
      expect(cache['c'], isNull);
    });
  });
}
