import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/repositories/mdblist_repository.dart';
import 'package:moonfin/data/viewmodels/library_browse_view_model.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A library with no collection type, the way the server reports a mixed one.
class _FakeItemsApi implements ItemsApi {
  Future<Map<String, dynamic>>? pendingPage;
  final List<String?> requestedSorts = <String?>[];
  final List<bool?> requestedRecursive = <bool?>[];

  @override
  Future<Map<String, dynamic>> getItems({
    bool? serverWide,
    String? parentId,
    List<String>? ids,
    List<String>? includeItemTypes,
    List<String>? excludeItemTypes,
    String? sortBy,
    String? sortOrder,
    int? startIndex,
    int? limit,
    bool? recursive,
    String? searchTerm,
    String? fields,
    List<String>? personIds,
    List<String>? artistIds,
    List<String>? filters,
    List<String>? seriesStatus,
    String? nameStartsWith,
    String? nameLessThan,
    List<String>? genreIds,
    List<String>? genres,
    bool? isFavorite,
    bool? collapseBoxSetItems,
    bool? enableTotalRecordCount,
    String? enableImageTypes,
    int? imageTypeLimit,
    List<String>? tags,
    List<String>? studios,
    DateTime? minPremiereDate,
    String? maxOfficialRating,
    bool? hasParentalRating,
    String? anyProviderIdEquals,
    List<String>? officialRatings,
    List<int>? years,
    List<String>? videoTypes,
    List<String>? audioLanguages,
    List<String>? subtitleLanguages,
    bool? hasSubtitles,
    bool? hasTrailer,
    bool? hasSpecialFeature,
    bool? hasThemeSong,
    bool? hasThemeVideo,
    bool? isHd,
    bool? is4K,
    bool? is3D,
  }) async {
    requestedSorts.add(sortBy);
    requestedRecursive.add(recursive);
    if (pendingPage != null) return pendingPage!;
    return <String, dynamic>{
      'TotalRecordCount': 2,
      'Items': [
        <String, dynamic>{'Id': 'series', 'Name': 'Loki', 'Type': 'Series'},
        <String, dynamic>{'Id': 'movie', 'Name': 'Eternals', 'Type': 'Movie'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getItem(
    String itemId, {
    String? mediaSourceId,
    String? fields,
  }) async => <String, dynamic>{'Name': 'Marvel'};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements MediaServerClient {
  _FakeClient(this.itemsApi, [this.displayApi]);
  final DisplayPreferencesApi? displayApi;
  @override
  DisplayPreferencesApi get displayPreferencesApi => displayApi ?? (throw StateError("no preferences"));

  @override
  final ItemsApi itemsApi;

  @override
  String get baseUrl => 'http://server';

  @override
  String? get userId => 'user';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMdbListRepository implements MdbListRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<LibraryBrowseViewModel> _viewModel(
  _FakeItemsApi api, {
  LibrarySortBy? savedSort,
  DisplayPreferencesApi? displayApi,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = PreferenceStore();
  await store.init();
  final prefs = UserPreferences(store);
  if (savedSort != null) {
    await prefs.set(UserPreferences.librarySortBy('mixed'), savedSort);
  }
  return LibraryBrowseViewModel(
    libraryId: 'mixed',
    client: _FakeClient(api, displayApi),
    prefs: prefs,
    mdbListRepository: _FakeMdbListRepository(),
  );
}

class _DisplayPreferences implements DisplayPreferencesApi {
  final pending = Completer<DisplayPreferences>();
  int calls = 0;
  @override
  Future<DisplayPreferences> getDisplayPreferences(String id, {String? client}) {
    calls++; return pending.future;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sorting a mixed library by name keeps shows and movies together', () async {
    final api = _FakeItemsApi();
    final vm = await _viewModel(api, savedSort: LibrarySortBy.name);

    await vm.load();

    expect(vm.sortBy, LibrarySortBy.name);
    expect(api.requestedSorts.first, 'SortName');
    expect(api.requestedRecursive.first, isFalse);
  });

  test('a mixed library with no saved sort opens with folders first', () async {
    final api = _FakeItemsApi();
    final vm = await _viewModel(api);

    await vm.load();

    expect(vm.sortBy, LibrarySortBy.foldersFirst);
    expect(api.requestedSorts.first, 'IsFolder,SortName');
  });

  test('a premiere date sort stays picked when the library opens again', () async {
    final api = _FakeItemsApi();
    final vm = await _viewModel(api, savedSort: LibrarySortBy.premiereDate);

    await vm.load();

    expect(vm.sortBy, LibrarySortBy.premiereDate);
    expect(api.requestedSorts.first, 'PremiereDate,SortName');
  });
  test('slow cosmetic preferences do not hold data and are shared on refresh', () async {
    final api = _FakeItemsApi(), display = _DisplayPreferences();
    final vm = await _viewModel(api, displayApi: display);
    addTearDown(vm.dispose);
    await vm.load();
    expect(vm.state, LibraryBrowseState.ready); expect(vm.items, hasLength(2));
    await vm.load(); expect(display.calls, 1);
    display.pending.complete(const DisplayPreferences(id: 'mixed', customPrefs: {'imageType': 'thumb'}));
    await pumpEventQueue();
    expect(vm.imageType.name, 'thumb');
  });
  test('same query keeps rows while refresh is pending; new sort clears them', () async {
    final api = _FakeItemsApi(); final vm = await _viewModel(api);
    addTearDown(vm.dispose); await vm.load();
    final reply = Completer<Map<String, dynamic>>(); api.pendingPage = reply.future;
    final refreshing = vm.load(); await pumpEventQueue();
    expect(vm.state, LibraryBrowseState.ready); expect(vm.isRefreshing, isTrue);
    expect(vm.items, hasLength(2)); expect(vm.hasMore, isFalse);
    reply.complete({'Items': [{'Id': 'new', 'Name': 'New', 'Type': 'Movie'}], 'TotalRecordCount': 1});
    await refreshing; expect(vm.items.single.id, 'new'); expect(vm.isRefreshing, isFalse);
  });

}
