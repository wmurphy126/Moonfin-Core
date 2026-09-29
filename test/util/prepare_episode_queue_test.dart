import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/util/prepare_episode_queue.dart';

AggregatedItem episode(
  String id, {
  bool hydrated = false,
  bool virtual = false,
}) => AggregatedItem(
  id: id,
  serverId: 's',
  rawData: {
    'Type': 'Episode',
    'IsVirtualItem': virtual,
    if (hydrated)
      'MediaSources': [
        {'Id': id, 'Protocol': 'File'},
      ],
    'UserData': {'PlaybackPositionTicks': 1200000000},
  },
);

void main() {
  test(
    'current and next start together and publish only when both finish',
    () async {
      final first = Completer<AggregatedItem>(),
          next = Completer<AggregatedItem>();
      final calls = <String>[];
      final original = [episode('a'), episode('b'), episode('c')];
      final preparing = prepareEpisodeQueue(
        original,
        startIndex: 0,
        hydrate: (item) {
          calls.add(item.id);
          return item.id == 'a' ? first.future : next.future;
        },
        ensureStillWanted: () {},
      );
      expect(calls, ['a', 'b']);
      next.complete(episode('b', hydrated: true));
      first.complete(episode('a', hydrated: true));
      final queue = await preparing;
      expect(queue.map((i) => i.id), ['a', 'b', 'c']);
      expect(original.first.mediaSources, isEmpty);
      expect(queue.first.playbackPosition, const Duration(seconds: 120));
      expect(queue[1].mediaSources, isNotEmpty);
    },
  );
  test(
    'an unplayable immediate next retains the existing truncation rule',
    () async {
      final queue = await prepareEpisodeQueue(
        [episode('a'), episode('b'), episode('c')],
        startIndex: 0,
        hydrate: (item) async =>
            episode(item.id, hydrated: item.id == 'a', virtual: item.id == 'b'),
        ensureStillWanted: () {},
      );
      expect(queue.map((i) => i.id), ['a']);
    },
  );
  test('canceled launch cannot commit a prepared queue', () async {
    var wanted = true;
    final reply = Completer<AggregatedItem>();
    final original = [episode('a')];
    final preparing = prepareEpisodeQueue(
      original,
      startIndex: 0,
      hydrate: (_) => reply.future,
      ensureStillWanted: () {
        if (!wanted) throw StateError('canceled');
      },
    );
    final check = expectLater(preparing, throwsStateError);
    wanted = false;
    reply.complete(episode('a', hydrated: true));
    await check;
    expect(original.single.mediaSources, isEmpty);
  });
}
