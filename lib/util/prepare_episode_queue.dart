import 'package:server_core/server_core.dart';

import '../data/models/aggregated_item.dart';
import 'episode_playability.dart';

/// Prepare the current and immediate next episode together, then commit their
/// metadata as one queue snapshot. Neither request depends on the other's data.
/// No stream is opened here and existing next-episode eligibility is retained.
Future<List<AggregatedItem>> prepareEpisodeQueue(
  List<AggregatedItem> queue, {
  required int startIndex,
  required Future<AggregatedItem> Function(AggregatedItem) hydrate,
  required void Function() ensureStillWanted,
}) async {
  ensureStillWanted();
  final snapshot = List<AggregatedItem>.of(queue);
  final next = startIndex + 1;
  final hydrated = await Future.wait([
    PerformanceTrace.measure(
      'play.prepare.current',
      () => hydrate(snapshot[startIndex]),
    ),
    if (next < snapshot.length)
      PerformanceTrace.measure(
        'play.prepare.next',
        () => hydrate(snapshot[next]),
      ),
  ]);
  ensureStillWanted();
  snapshot[startIndex] = hydrated.first;
  if (next < snapshot.length) {
    snapshot[next] = hydrated[1];
    if (!isEligibleNextEpisodeCandidate(snapshot[next]))
      return snapshot.sublist(0, next);
  }
  return snapshot;
}
