import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/viewmodels/seerr_discover_view_model.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/preference/seerr_preferences.dart';

class _Repo extends Mock implements SeerrRepository {}

class _Prefs extends Mock implements SeerrPreferences {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Repo repo;
  late _Prefs prefs;
  late SeerrDiscoverViewModel vm;
  setUp(() {
    repo = _Repo();
    prefs = _Prefs();
    when(() => repo.ensureInitialized(force: any(named: 'force')))
        .thenAnswer((_) async {});
    when(() => repo.isAvailable).thenReturn(true);
    when(() => prefs.blockNsfw).thenReturn(false);
    when(() => prefs.fetchLimit).thenReturn(SeerrFetchLimit.small);
    vm = SeerrDiscoverViewModel(repo, prefs);
  });
  tearDown(() => vm.dispose());

  test(
    'base rows finish while enrichment is bounded and can be abandoned',
    () async {
      when(() => prefs.activeRows)
          .thenReturn([SeerrRowType.yourWatchlist, SeerrRowType.trending]);
      final items = List.generate(
        15,
        (id) =>
            SeerrDiscoverItem(id: id + 1, mediaType: 'movie', title: 'Base'),
      );
      when(() => repo.getWatchlist(page: 1)).thenAnswer(
        (_) async => SeerrDiscoverPage(
          page: 1,
          totalPages: 1,
          totalResults: 15,
          results: items,
        ),
      );
      when(
        () => repo.getTrending(
          offset: any(named: 'offset'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const SeerrDiscoverPage(
          page: 1,
          totalPages: 1,
          totalResults: 0,
          results: [],
        ),
      );
      final details = <Completer<SeerrMovieDetails>>[];
      when(() => repo.getMovieDetails(any())).thenAnswer((_) {
        final pending = Completer<SeerrMovieDetails>();
        details.add(pending);
        return pending.future;
      });
      final owner = Object();
      vm.attach(owner);
      await vm.load();
      expect(vm.rows.first.items, hasLength(15));
      expect(vm.rows.every((r) => !r.isLoading), isTrue);
      expect(details, hasLength(4));
      vm.detach(owner);
      for (final detail in details) {
        detail.completeError(StateError('offline'));
      }
      await pumpEventQueue();
      expect(details, hasLength(4));
      expect(vm.rows.first.items, hasLength(15));
      verify(() => repo.ensureInitialized(force: false)).called(1);
    },
  );

  test(
    'slow permission check does not block trending or expose forbidden row',
    () async {
      when(() => prefs.activeRows)
          .thenReturn([SeerrRowType.recentlyAdded, SeerrRowType.trending]);
      final permission = Completer<SeerrUser>();
      when(repo.getCurrentUser).thenAnswer((_) => permission.future);
      when(
        () => repo.getTrending(
          offset: any(named: 'offset'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const SeerrDiscoverPage(
          page: 1,
          totalPages: 1,
          totalResults: 1,
          results: [
            SeerrDiscoverItem(id: 1, mediaType: 'movie', title: 'Ready'),
          ],
        ),
      );
      final loading = vm.load();
      await pumpEventQueue();
      expect(vm.rows.last.items.single.title, 'Ready');
      verifyNever(() => repo.getRecentlyAdded(limit: any(named: 'limit')));
      permission.complete(const SeerrUser(id: 2, permissions: 0));
      await loading;
      expect(vm.rows.map((r) => r.type), [SeerrRowType.trending]);
    },
  );
  test(
    'pagination while enriching retains patches and enriches the new page',
    () async {
      when(() => prefs.activeRows).thenReturn([SeerrRowType.yourWatchlist]);
      when(() => repo.getWatchlist(page: 1)).thenAnswer(
        (_) async => const SeerrDiscoverPage(
          page: 1,
          totalPages: 2,
          totalResults: 2,
          results: [SeerrDiscoverItem(id: 1, mediaType: 'movie', title: 'One')],
        ),
      );
      final nextPage = Completer<SeerrDiscoverPage>();
      when(() => repo.getWatchlist(page: 2)).thenAnswer((_) => nextPage.future);
      final one = Completer<SeerrMovieDetails>();
      when(() => repo.getMovieDetails(1)).thenAnswer((_) => one.future);
      when(() => repo.getMovieDetails(2)).thenAnswer(
        (_) async => SeerrMovieDetails.fromJson({
          'id': 2,
          'title': 'Two',
          'posterPath': '/two',
        }),
      );
      await vm.load();
      final paging = vm.loadMore(0);
      one.complete(
        SeerrMovieDetails.fromJson({
          'id': 1,
          'title': 'One',
          'posterPath': '/one',
        }),
      );
      await pumpEventQueue();
      expect(vm.rows.single.items.single.posterPath, '/one');
      nextPage.complete(
        const SeerrDiscoverPage(
          page: 2,
          totalPages: 2,
          totalResults: 2,
          results: [SeerrDiscoverItem(id: 2, mediaType: 'movie', title: 'Two')],
        ),
      );
      await paging;
      await pumpEventQueue();
      expect(vm.rows.single.items.map((e) => e.posterPath), ['/one', '/two']);
    },
  );
}
