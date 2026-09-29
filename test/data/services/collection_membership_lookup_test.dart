import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/services/collection_membership_lookup.dart';
import 'package:server_core/server_core.dart';

class _Client extends Mock implements MediaServerClient {}

class _Items extends Fake implements ItemsApi {
  _Items(this.count);
  final int count;
  int scans = 0, running = 0, peak = 0, checks = 0;
  final offsets = <int>[];
  Completer<List<Map<String, dynamic>>>? ancestors;
  @override
  Future<List<Map<String, dynamic>>> getAncestors(String id) {
    scans++;
    return ancestors?.future ?? Future.value([]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getItems)
      return _items(invocation.namedArguments);
    return super.noSuchMethod(invocation);
  }

  Future<Map<String, dynamic>> _items(Map<Symbol, dynamic> args) async {
    final parent = args[#parentId] as String?;
    if (parent != null) {
      expect(args[#recursive], isNull);
      running++;
      peak = max(peak, running);
      checks++;
      await Future<void>.delayed(Duration.zero);
      running--;
      return {
        'Items': [
          {'Id': int.parse(parent) % 2 == 0 ? 'episode' : 'series'},
        ],
      };
    }
    final offset = args[#startIndex] as int;
    final limit = args[#limit] as int;
    offsets.add(offset);
    return {
      'Items': [
        for (var i = offset; i < min(count, offset + limit); i++)
          {'Id': '$i', 'Name': 'Collection $i', 'Type': 'BoxSet'},
      ],
      'TotalRecordCount': count,
    };
  }
}

void main() {
  for (final count in [0, 1, 500]) {
    test(
      '$count collections preserve direct memberships with bounded work',
      () async {
        final client = _Client();
        final items = _Items(count);
        when(() => client.itemsApi).thenReturn(items);
        when(() => client.baseUrl).thenReturn('https://server');
        when(() => client.userId).thenReturn('user');
        final owner = RequestWorkScope();
        final result = await CollectionMembershipLookup.forClient(client)
            .find(client, 'episode', owner: owner);
        expect(result.length, (count + 1) ~/ 2);
        expect(items.checks, count);
        expect(items.peak, lessThanOrEqualTo(2));
        expect(items.offsets, count == 500 ? [0, 200, 400] : [0]);
        owner.cancel();
      },
    );
  }
  test('one departing subscriber does not cancel another, last departure stops scan', () async {
    final client = _Client();
    final items = _Items(500)..ancestors = Completer();
    when(() => client.itemsApi).thenReturn(items);
    when(() => client.baseUrl).thenReturn('https://server');
    when(() => client.userId).thenReturn('user');
    final lookup = CollectionMembershipLookup.forClient(client);
    final first = RequestWorkScope(), second = RequestWorkScope();
    final a = lookup.find(client, 'episode', owner: first);
    final b = lookup.find(client, 'episode', owner: second);
    first.cancel();
    expect(await a, isEmpty);
    expect(items.scans, 1);
    second.cancel();
    expect(await b, isEmpty);
    items.ancestors!.complete([]);
    await pumpEventQueue();
    expect(items.checks, 0);
    expect(items.offsets, isEmpty);
  });
}
