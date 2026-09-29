import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/performance_recording.dart';

void main() {
  test('counter differences never cross a decoder epoch or stale sample', () {
    final a = <String, Object?>{
      'player': 1,
      'decoderEpoch': 2,
      'nativeUs': 10,
      'rendered': 20,
      'dropped': 2,
      'skipped': 3,
    };
    final b = {
      ...a,
      'nativeUs': 30,
      'rendered': 28,
      'dropped': 3,
      'skipped': 9,
    };
    expect(decoderCounterDeltas(b, a), {
      'deltaValid': true,
      'intervalUs': 20,
      'deltaRendered': 8,
      'deltaDropped': 1,
      'deltaSkipped': 6,
    });
    expect(decoderCounterDeltas({...b, 'decoderEpoch': 3}, a), {
      'deltaValid': false,
    });
    expect(decoderCounterDeltas({...b, 'player': 2}, a), {'deltaValid': false});
    expect(decoderCounterDeltas(a, a), {'deltaValid': false});
    expect(decoderCounterDeltas({...b, 'rendered': 0}, a), {
      'deltaValid': false,
    });
  });
}
