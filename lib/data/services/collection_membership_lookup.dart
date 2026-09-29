import 'package:server_core/server_core.dart';

import '../utils/bounded_concurrency.dart';

typedef CollectionMatch = ({String name, Map<String, dynamic> rawData});

/// Shares only concurrent scans, so membership never outlives a mutation or
/// account change. Completed results are deliberately not a persistent index.
class CollectionMembershipLookup {
  static final _clients = Expando<CollectionMembershipLookup>();
  static CollectionMembershipLookup forClient(MediaServerClient client) =>
      _clients[client] ??= CollectionMembershipLookup();
  final Map<(String?, String, String), _Scan> _pending = {};

  Future<Map<String, CollectionMatch>> find(
    MediaServerClient client,
    String item, {
    required RequestWorkScope owner,
  }) async {
    if (owner.isCanceled) return {};
    final key = (client.userId, client.baseUrl, item);
    var scan = _pending[key];
    if (scan == null) {
      scan = _Scan();
      final created = scan;
      // A scan's cancellation belongs to all subscribers, not its first page.
      created.result = created.scope.run(
        () => _find(client, item, created.scope),
      );
      // Bound retained keys; an overflow read still works, without memoization.
      if (_pending.length < 128) _pending[key] = created;
    }
    final active = scan;
    active.users++;
    PerformanceTrace.event('collections.scan.owners', {
      'users': active.users,
      'pending': _pending.length,
    });
    try {
      return await Future.any([
        active.result,
        owner.whenCanceled.then<Map<String, CollectionMatch>>((_) => {}),
      ]);
    } finally {
      active.users--;
      if (active.users == 0) {
        if (identical(_pending[key], active)) _pending.remove(key);
        active.scope.cancel();
      }
    }
  }

  Future<Map<String, CollectionMatch>> _find(
    MediaServerClient client,
    String item,
    RequestWorkScope scope,
  ) async {
    final result = <String, CollectionMatch>{};
    final checked = <String>{};
    final order = <String, int>{};
    Future<void> consider(Map<String, dynamic> candidate) async {
      final id = candidate['Id']?.toString(),
          name = candidate['Name']?.toString();
      if (scope.isCanceled || id == null || id.isEmpty || name == null) return;
      order.putIfAbsent(id, () => order.length);
      if (!checked.add(id)) {
        if (result.containsKey(id))
          result[id] = (name: name, rawData: Map.of(candidate));
        return;
      }
      try {
        final data = await client.itemsApi.getItems(
          parentId: id,
          fields: 'BasicSyncInfo',
        );
        final members = (data['Items'] as List?) ?? const [];
        PerformanceTrace.event('collections.membership_checked', {
          'items': members.length,
        });
        if (members.whereType<Map>().any((m) => m['Id']?.toString() == item)) {
          result[id] = (name: name, rawData: Map.of(candidate));
        }
      } catch (_) {
        checked.remove(id);
      }
    }

    try {
      final ancestors = await client.itemsApi.getAncestors(item);
      await mapBounded<Map<String, dynamic>, void>(
        ancestors.where((a) => a['Type'] == 'BoxSet').toList(),
        2,
        consider,
      );
      const pageSize = 200;
      var offset = 0;
      while (!scope.isCanceled) {
        final data = await client.itemsApi.getItems(
          includeItemTypes: ['BoxSet'],
          recursive: true,
          sortBy: 'SortName',
          fields: 'BasicSyncInfo,PrimaryImageAspectRatio,ImageTags,ProviderIds',
          startIndex: offset,
          limit: pageSize,
          enableTotalRecordCount: true,
        );
        final page = (data['Items'] as List?) ?? const [];
        PerformanceTrace.event('collections.page', {
          'items': page.length,
          'offset': offset,
        });
        await mapBounded<Map<String, dynamic>, void>(
          page
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList(),
          2,
          consider,
        );
        if (page.length < pageSize) break;
        offset += page.length;
      }
    } catch (_) {
      // Preserve collections already verified if a later page is unavailable.
    }
    final ids = result.keys.toList()
      ..sort((a, b) => order[a]!.compareTo(order[b]!));
    return {for (final id in ids) id: result[id]!};
  }
}

class _Scan {
  final scope = RequestWorkScope(priority: RequestPriority.background);
  late final Future<Map<String, CollectionMatch>> result;
  int users = 0;
}
