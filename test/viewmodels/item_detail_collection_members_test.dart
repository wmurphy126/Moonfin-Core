import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/repositories/item_mutation_repository.dart';
import 'package:moonfin/data/repositories/mdblist_repository.dart';
import 'package:moonfin/data/repositories/tmdb_repository.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/data/viewmodels/item_detail_view_model.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends Mock implements MediaServerClient {}

class _ItemsApi extends Mock implements ItemsApi {}

class _PluginSyncService extends Mock implements PluginSyncService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Client client;
  late _ItemsApi itemsApi;

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    final pluginSync = _PluginSyncService();
    when(() => pluginSync.seerrAvailable).thenReturn(false);
    GetIt.instance.registerSingleton<PluginSyncService>(pluginSync);

    client = _Client();
    itemsApi = _ItemsApi();
    when(() => client.itemsApi).thenReturn(itemsApi);
    when(() => client.baseUrl).thenReturn('http://server');

    when(
      () => itemsApi.getItem('boxset-1', mediaSourceId: any(named: 'mediaSourceId')),
    ).thenAnswer(
      (_) async => {'Id': 'boxset-1', 'Type': 'BoxSet', 'Name': 'Crossovers'},
    );

    // The strict shape is the assertion. A page fetch that walks the tree or
    // filters by type carries extra arguments, misses this stub, and the grid
    // stays empty, which is the reported bug.
    when(
      () => itemsApi.getItems(
        parentId: 'boxset-1',
        startIndex: 0,
        limit: any(named: 'limit'),
        fields: 'PrimaryImageAspectRatio,BasicSyncInfo,People',
      ),
    ).thenAnswer(
      (_) async => {
        'Items': [
          {'Id': 'ep-flash', 'Type': 'Episode', 'Name': 'Flash vs. Arrow', 'SeriesName': 'The Flash'},
          {'Id': 'ep-arrow', 'Type': 'Episode', 'Name': 'The Brave and the Bold', 'SeriesName': 'Arrow'},
        ],
        'TotalRecordCount': 2,
      },
    );
  });

  tearDown(() => GetIt.instance.reset());

  test('collection grid asks for the members themselves, episodes included',
      () async {
    final tmdb = TmdbRepository(client);
    final vm = ItemDetailViewModel(
      itemId: 'boxset-1',
      client: client,
      mutations: ItemMutationRepository(client),
      mdbListRepository: MdbListRepository(client, tmdb),
      tmdbRepository: tmdb,
    );

    await vm.load();
    // load() kicks the grid fetch off without awaiting it, so give the
    // page a moment to land before looking.
    for (var i = 0; i < 100 && vm.collectionItems.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(vm.collectionItems, hasLength(2));
    expect(vm.collectionItems.map((i) => i.type), everyElement('Episode'));
    expect(vm.collectionItems.first.name, 'Flash vs. Arrow');
  });
  Future<ItemDetailViewModel> series({String id = '12345'}) async {
    when(() => itemsApi.getItem(id, mediaSourceId: any(named: 'mediaSourceId')))
        .thenAnswer((_) async => {'Id': id, 'Name': 'Series', 'Type': 'Series'});
    final tmdb = TmdbRepository(client);
    final vm = ItemDetailViewModel(itemId: id, client: client,
      mutations: ItemMutationRepository(client), mdbListRepository: MdbListRepository(client, tmdb), tmdbRepository: tmdb);
    addTearDown(vm.dispose);
    await vm.load();
    return vm;
  }
  test('episode 400 does not retry on repeated builds; explicit retry works', () async {
    final vm = await series();
    final request = RequestOptions(path: '/Shows/12345/Episodes');
    when(() => itemsApi.getEpisodes('12345', fields: any(named: 'fields')))
      .thenThrow(DioException(requestOptions: request, response: Response(requestOptions: request, statusCode: 400)));
    for (var i = 0; i < 20; i++) { await vm.loadAllSeriesEpisodes(); }
    verify(() => itemsApi.getEpisodes('12345', fields: any(named: 'fields'))).called(1);
    expect(vm.seriesEpisodesError, isA<DioException>());
    when(() => itemsApi.getEpisodes('12345', fields: any(named: 'fields'))).thenAnswer((_) async => {'Items': []});
    await vm.refreshSeriesEpisodes();
    expect(vm.seriesEpisodesLoaded, isTrue); expect(vm.seriesEpisodesError, isNull);
  });
  test('concurrent local series consumers share one episode request', () async {
    final vm = await series();
    final reply = Completer<Map<String, dynamic>>();
    when(() => itemsApi.getEpisodes('12345', fields: any(named: 'fields'))).thenAnswer((_) => reply.future);
    final a = vm.loadAllSeriesEpisodes(), b = vm.loadAllSeriesEpisodes();
    expect(identical(a, b), isTrue);
    reply.complete({'Items': []}); await Future.wait([a, b]);
    verify(() => itemsApi.getEpisodes('12345', fields: any(named: 'fields'))).called(1);
  });
  test('synthetic series never enters Jellyfin episode endpoint', () async {
    final tmdb = TmdbRepository(client);
    final vm = ItemDetailViewModel(itemId: 'tmdb:tv:42', client: client,
      mutations: ItemMutationRepository(client), mdbListRepository: MdbListRepository(client, tmdb), tmdbRepository: tmdb);
    addTearDown(vm.dispose);
    for (var i = 0; i < 20; i++) { await vm.loadAllSeriesEpisodes(); }
    verifyNever(() => itemsApi.getEpisodes(any(), fields: any(named: 'fields')));
  });
  test('only transient episode errors get a bounded retry respecting Retry-After', () {
    DioException error(int status, [String? retry]) {
      final request = RequestOptions(path: '/episodes');
      return DioException(requestOptions: request, response: Response(requestOptions: request,
        statusCode: status, headers: Headers.fromMap({if (retry != null) 'retry-after': [retry]})));
    }
    expect(episodeRetryDelay(error(400)), isNull); expect(episodeRetryDelay(error(404)), isNull);
    expect(episodeRetryDelay(error(429, '4')), const Duration(seconds: 4));
    expect(episodeRetryDelay(error(503)), const Duration(seconds: 1));
    expect(episodeRetryDelay(error(429, '120')), isNull);
  });

}
