import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/repositories/search_repository.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/viewmodels/search_view_model.dart';
import 'package:server_core/server_core.dart';

class _Search extends Mock implements SearchRepository {}

class _Client extends Mock implements MediaServerClient {}

class _Seerr extends Mock implements SeerrRepository {}

void main() {
  late _Search search;
  late _Client client;
  late _Seerr seerr;
  late SearchViewModel vm;
  List<AggregatedItem> items(String id) => [
    AggregatedItem(
      id: id,
      serverId: 'server',
      rawData: {'Type': 'Movie', 'Name': id},
    ),
  ];
  setUp(() {
    search = _Search();
    client = _Client();
    seerr = _Seerr();
    when(() => client.gamesApi).thenReturn(null);
    when(() => search.searchPeople(any(), limit: any(named: 'limit')))
        .thenAnswer((_) async => []);
    when(search.fetchLiveTvChannels).thenAnswer((_) async => []);
    when(() => seerr.ensureInitialized()).thenAnswer((_) async {});
    when(() => seerr.isAvailable).thenReturn(true);
    vm = SearchViewModel(search, client, seerrRepository: seerr);
  });
  tearDown(() => vm.dispose());

  test('library publishes while Seerr and people are still waiting', () async {
    final people = Completer<List<AggregatedItem>>();
    final remote = Completer<SeerrDiscoverPage>();
    when(
      () => search.search(
        any(),
        parentId: any(named: 'parentId'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => items('local'));
    when(() => search.searchPeople(any(), limit: any(named: 'limit')))
        .thenAnswer((_) => people.future);
    when(() => seerr.search(any(), limit: any(named: 'limit')))
        .thenAnswer((_) => remote.future);
    vm.searchImmediate('query');
    await pumpEventQueue();
    expect(vm.results.single.items.single.id, 'local');
    expect(vm.state, SearchState.loading);
    expect(vm.pendingCategories, containsAll(['seerr', 'people']));
    people.complete([]);
    remote.complete(
      const SeerrDiscoverPage(
        page: 1,
        totalPages: 1,
        totalResults: 0,
        results: [],
      ),
    );
    await pumpEventQueue();
    expect(vm.state, SearchState.ready);
    expect(vm.results.single.items.single.id, 'local');
  });

  test('A B A cannot publish the first A after the final A', () async {
    final replies = <Completer<List<AggregatedItem>>>[];
    when(
      () => search.search(
        any(),
        parentId: any(named: 'parentId'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) {
      final reply = Completer<List<AggregatedItem>>();
      replies.add(reply);
      return reply.future;
    });
    when(() => seerr.isAvailable).thenReturn(false);
    for (final query in ['a', 'b', 'a']) {
      vm.searchImmediate(query);
      await pumpEventQueue();
    }
    replies[2].complete(items('new'));
    await pumpEventQueue();
    replies[0].complete(items('old'));
    replies[1].complete(items('middle'));
    await pumpEventQueue();
    expect(vm.results.single.items.single.id, 'new');
    expect(vm.state, SearchState.ready);
  });

  test('a library failure preserves successful people', () async {
    when(
      () => search.search(
        any(),
        parentId: any(named: 'parentId'),
        limit: any(named: 'limit'),
      ),
    ).thenThrow(StateError('offline'));
    when(() => search.searchPeople(any(), limit: any(named: 'limit')))
        .thenAnswer(
          (_) async => [
            AggregatedItem(
              id: 'p',
              serverId: 'server',
              rawData: {'Type': 'Person'},
            ),
          ],
        );
    when(() => seerr.isAvailable).thenReturn(false);
    vm.searchImmediate('a');
    await pumpEventQueue();
    expect(vm.results.single.items.single.id, 'p');
    expect(vm.state, SearchState.ready);
    expect(vm.categoryErrors, contains('library'));
  });
}
