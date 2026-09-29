import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';

import '../../l10n/current_app_localizations.dart';
import '../../util/accent_folding.dart';
import '../models/aggregated_item.dart';
import '../repositories/multi_server_repository.dart';
import '../repositories/search_repository.dart';
import '../repositories/seerr_repository.dart';
import '../services/seerr/seerr_api_models.dart';

class SearchResultGroup {
  final String title;
  final List<String> itemTypes;
  final List<AggregatedItem> items;

  const SearchResultGroup({
    required this.title,
    required this.itemTypes,
    this.items = const [],
  });

  SearchResultGroup copyWith({List<AggregatedItem>? items}) =>
      SearchResultGroup(
        title: title,
        itemTypes: itemTypes,
        items: items ?? this.items,
      );
}

/// A single retro game that matched the query. Games live behind the Moonbase
/// plugin rather than the normal /Items search, so they carry their owning
/// [libraryId] (which [GameSummary] itself does not expose) for navigation.
class GameSearchResult {
  final String libraryId;
  final GameSummary game;

  const GameSearchResult({required this.libraryId, required this.game});
}

enum SearchState { idle, loading, ready, error }

class SearchViewModel extends ChangeNotifier {
  final SearchRepository _searchRepository;
  final MediaServerClient _client;
  final String? _scopedParentId;
  // Only set when search should cover every signed-in server.
  final MultiServerRepository? _multiServerRepository;
  SeerrRepository? _seerrRepository;

  SearchViewModel(
    this._searchRepository,
    this._client, {
    SeerrRepository? seerrRepository,
    String? scopedParentId,
    MultiServerRepository? multiServerRepository,
  }) : _seerrRepository = seerrRepository,
       _multiServerRepository = multiServerRepository,
       _scopedParentId = (scopedParentId != null && scopedParentId.isNotEmpty)
           ? scopedParentId
           : null;

  void setSeerrRepository(SeerrRepository repo) {
    _seerrRepository = repo;
  }

  ImageApi imageApiFor(AggregatedItem item) =>
      _multiServerRepository?.getImageApiForServer(item.serverId) ??
      _client.imageApi;

  Map<String, String> _serverNames = const {};

  /// The server [item] came from, or null when only one server was searched.
  String? serverNameFor(AggregatedItem item) => _serverNames[item.serverId];

  SearchState _state = SearchState.idle;
  SearchState get state => _state;

  String _query = '';
  String get query => _query;

  List<SearchResultGroup> _results = const [];
  List<SearchResultGroup> get results => _results;

  List<SeerrDiscoverItem> _seerrResults = const [];
  List<SeerrDiscoverItem> get seerrResults => _seerrResults;

  List<GameSearchResult> _gameResults = const [];
  List<GameSearchResult> get gameResults => _gameResults;

  // All games across every game library, fetched once per session and filtered
  // client-side since the plugin exposes no search endpoint.
  Future<List<GameSearchResult>>? _allGamesFuture;

  Object? _error;
  Object? get error => _error;

  Timer? _debounceTimer;
  int _generation = 0;
  RequestWorkScope? _work;
  bool _disposed = false;
  final Set<String> _pendingCategories = {};
  final Map<String, Object> _categoryErrors = {};
  Set<String> get pendingCategories => Set.unmodifiable(_pendingCategories);
  Map<String, Object> get categoryErrors => Map.unmodifiable(_categoryErrors);
  PerformanceSpan? _inputSpan;

  static const _debounceMs = 600;
  static const _resultLimit = 24;
  static const _globalFetchLimit = 240;

  static List<SearchResultGroup> _bookSearchGroups() {
    final l10n = currentAppLocalizations();
    return [
      SearchResultGroup(title: l10n.books, itemTypes: const ['Book']),
      SearchResultGroup(title: l10n.audiobooks, itemTypes: const ['AudioBook']),
    ];
  }

  static List<SearchResultGroup> _searchGroups() {
    final l10n = currentAppLocalizations();
    return [
      SearchResultGroup(title: l10n.books, itemTypes: const ['Book']),
      SearchResultGroup(title: l10n.movies, itemTypes: const ['Movie']),
      SearchResultGroup(title: l10n.series, itemTypes: const ['Series']),
      SearchResultGroup(title: l10n.seasons, itemTypes: const ['Season']),
      SearchResultGroup(title: l10n.episodes, itemTypes: const ['Episode']),
      SearchResultGroup(title: l10n.videos, itemTypes: const ['Video']),
      SearchResultGroup(
        title: l10n.musicVideos,
        itemTypes: const ['MusicVideo'],
      ),
      SearchResultGroup(title: l10n.trailers, itemTypes: const ['Trailer']),
      SearchResultGroup(title: l10n.programs, itemTypes: const ['Program']),
      SearchResultGroup(
        title: l10n.channels,
        itemTypes: const ['LiveTvChannel', 'TvChannel'],
      ),
      SearchResultGroup(title: l10n.playlists, itemTypes: const ['Playlist']),
      SearchResultGroup(
        title: l10n.artists,
        itemTypes: const ['MusicArtist', 'AlbumArtist'],
      ),
      SearchResultGroup(title: l10n.albums, itemTypes: const ['MusicAlbum']),
      SearchResultGroup(title: l10n.songs, itemTypes: const ['Audio']),
      SearchResultGroup(
        title: l10n.photoAlbums,
        itemTypes: const ['PhotoAlbum'],
      ),
      SearchResultGroup(title: l10n.photos, itemTypes: const ['Photo']),
      SearchResultGroup(title: l10n.collections, itemTypes: const ['BoxSet']),
      SearchResultGroup(title: l10n.people, itemTypes: const ['Person']),
      SearchResultGroup(
        title: l10n.folders,
        itemTypes: const ['Folder', 'CollectionFolder', 'UserView'],
      ),
    ];
  }

  void searchDebounced(String query) {
    final trimmed = query.trim();
    if (trimmed == _query) return;
    _query = trimmed;
    final generation = ++_generation;
    _work?.cancel();
    _work = RequestWorkScope();
    _inputSpan?.end(outcome: 'superseded');
    _inputSpan = trimmed.isEmpty
        ? null
        : PerformanceTrace.begin('search.input_to_first_result');

    _debounceTimer?.cancel();

    if (trimmed.isEmpty) {
      _results = const [];
      _seerrResults = const [];
      _gameResults = const [];
      _pendingCategories.clear();
      _categoryErrors.clear();
      _state = SearchState.idle;
      notifyListeners();
      return;
    }

    _state = SearchState.loading;
    notifyListeners();

    _debounceTimer = Timer(
      const Duration(milliseconds: _debounceMs),
      () => _executeSearch(trimmed, generation),
    );
  }

  void searchImmediate(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _query = trimmed;
    final generation = ++_generation;
    _work?.cancel();
    _work = RequestWorkScope();
    _inputSpan?.end(outcome: 'superseded');
    _inputSpan = trimmed.isEmpty
        ? null
        : PerformanceTrace.begin('search.input_to_first_result');
    _debounceTimer?.cancel();
    _state = SearchState.loading;
    notifyListeners();
    unawaited(_executeSearch(trimmed, generation));
  }

  Future<void> _executeSearch(String query, int generation) =>
      PerformanceTrace.measure(
        'search.execute',
        () => _work!.run(() => _executeSearchRecorded(query, generation)),
      );

  Future<void> _executeSearchRecorded(String query, int generation) async {
    bool current() => !_disposed && generation == _generation;
    if (!current()) return;
    PerformanceTrace.observed(this, 'search');
    _error = null;
    _categoryErrors.clear();
    final groups = _scopedParentId != null
        ? _bookSearchGroups()
        : _searchGroups();
    final populated = <String, List<AggregatedItem>>{};
    var seerr = const <SeerrDiscoverItem>[];
    var games = const <GameSearchResult>[];
    var published = false;
    _pendingCategories
      ..clear()
      ..addAll([
        'library',
        'seerr',
        'games',
        if (_scopedParentId == null) ...['people', 'channels'],
      ]);
    void publish(String category) {
      if (!current()) return;
      final results = [
        for (final group in groups)
          if (populated[group.title]?.isNotEmpty ?? false)
            group.copyWith(items: populated[group.title]),
      ];
      final hasData =
          results.isNotEmpty || seerr.isNotEmpty || games.isNotEmpty;
      if (hasData || published || _pendingCategories.isEmpty) {
        _results = results;
        _seerrResults = seerr;
        _gameResults = games;
        published = true;
      }
      if (hasData) {
        _inputSpan?.end(data: {'generation': generation});
        _inputSpan = null;
      }
      if (_pendingCategories.isEmpty) {
        _error = _categoryErrors['library'];
        _state = !hasData && _error != null
            ? SearchState.error
            : SearchState.ready;
        _inputSpan?.end(outcome: 'no_results');
        _inputSpan = null;
      }
      PerformanceTrace.event('search.category.data.ready', {
        'kind': category,
        'generation': generation,
        'groups': results.length,
        'pending': _pendingCategories.length,
      });
      notifyListeners();
    }

    Future<void> category(String name, Future<void> Function() fetch) async {
      try {
        await PerformanceTrace.measure('search.$name', fetch);
      } catch (error) {
        if (current()) _categoryErrors[name] = error;
      } finally {
        if (current()) {
          _pendingCategories.remove(name);
          publish(name);
        }
      }
    }

    final requests = <Future<void>>[
      category('seerr', () async => seerr = await _fetchSeerrResults(query)),
      category(
        'games',
        () async => games = _scopedParentId != null
            ? []
            : await _fetchGameResults(query),
      ),
      category('library', () async {
        if (_scopedParentId != null) {
          await Future.wait(
            groups.map((group) async {
              populated[group.title] = await _searchRepository.search(
                query,
                includeItemTypes: group.itemTypes,
                parentId: _scopedParentId,
                limit: _resultLimit,
              );
              publish('library_group');
            }),
          );
        } else {
          final sessions = await _multiServerRepository?.getLoggedInServers();
          if (!current()) return;
          _serverNames = sessions != null && sessions.length > 1
              ? {
                  for (final session in sessions)
                    session.server.id: session.server.name,
                }
              : const {};
          final perServer = await _searchEachServer(
            (repo) => repo.search(
              query,
              parentId: _scopedParentId,
              limit: _globalFetchLimit,
            ),
            label: 'search',
          );
          for (final group in groups) {
            if (group.itemTypes.contains('Person') ||
                group.itemTypes.contains('LiveTvChannel'))
              continue;
            populated[group.title] = _interleave([
              for (final items in perServer)
                items
                    .where((item) => group.itemTypes.contains(item.type))
                    .toList(),
            ]).take(_resultLimit).toList();
          }
          PerformanceTrace.event('search.library.ready', {
            'generation': generation,
          });
        }
      }),
      if (_scopedParentId == null) ...[
        category('people', () async {
          final results = await _searchEachServer(
            (repo) => repo.searchPeople(query, limit: _resultLimit),
            label: 'people search',
          );
          populated[groups
              .firstWhere((g) => g.itemTypes.contains('Person'))
              .title] = _interleave(results)
              .take(_resultLimit)
              .toList();
        }),
        category('channels', () async {
          populated[groups
              .firstWhere((g) => g.itemTypes.contains('LiveTvChannel'))
              .title] = await _channelMatches(
            query,
          );
        }),
      ],
    ];
    await Future.wait(requests);
  }

  Future<List<List<AggregatedItem>>> _searchEachServer(
    Future<List<AggregatedItem>> Function(SearchRepository repository) search, {
    required String label,
  }) async {
    final multiServer = _multiServerRepository;
    if (multiServer == null) return [await search(_searchRepository)];
    return multiServer.searchEachServer(search, label: label);
  }

  /// Takes one result from each server in turn, so every server keeps its own
  /// ranking and none crowds the others out of a capped group.
  static List<AggregatedItem> _interleave(
    List<List<AggregatedItem>> perServer,
  ) {
    final longest = perServer.fold(0, (most, items) => max(most, items.length));
    return [
      for (var i = 0; i < longest; i++)
        for (final items in perServer)
          if (i < items.length) items[i],
    ];
  }

  // The lineup is fetched once per search session and reused across queries,
  // since /LiveTv/Channels has no search parameter of its own.
  Future<List<AggregatedItem>>? _channelsFuture;

  Future<List<AggregatedItem>> _channelMatches(String query) async {
    // Channels come back wholesale rather than through a search the server
    // answers, so the folding it would have done has to happen here.
    final q = foldForSearch(query.trim());
    if (q.isEmpty || q.startsWith('studio:')) return const [];
    _channelsFuture ??= RequestWorkScope.detached(() => _searchEachServer(
      (repository) => repository.fetchLiveTvChannels(),
      label: 'channel lineup',
    ).then((perServer) => perServer.expand((channels) => channels).toList()));
    try {
      final all = await _channelsFuture!;
      return all
          .where((c) => foldForSearch(c.name).contains(q))
          .take(_resultLimit)
          .toList();
    } catch (_) {
      // A server without Live TV shouldn't break search. Retry next query in
      // case the failure was transient.
      _channelsFuture = null;
      rethrow;
    }
  }

  Future<List<SeerrDiscoverItem>> _fetchSeerrResults(String query) async {
    if (_scopedParentId != null) return const [];
    if (query.trim().toLowerCase().startsWith('studio:')) return const [];
    final repo = _seerrRepository;
    if (repo == null) return const [];
    try {
      await repo.ensureInitialized();
      if (!repo.isAvailable) return const [];
      final page = await repo.search(query, limit: _resultLimit);
      return page.results.where((item) => !item.isBlacklisted).toList();
    } catch (_) {
      rethrow;
    }
  }

  Future<List<GameSearchResult>> _fetchGameResults(String query) async {
    // Games have no search endpoint, so the whole set is matched here and the
    // folding is this side's to do.
    final q = foldForSearch(query.trim());
    if (q.isEmpty || q.startsWith('studio:')) return const [];
    final gamesApi = _client.gamesApi;
    if (gamesApi == null) return const [];
    try {
      _allGamesFuture ??= RequestWorkScope.detached(() => _fetchAllGames(gamesApi));
      final all = await _allGamesFuture!;
      return all
          .where(
            (r) =>
                foldForSearch(r.game.title).contains(q) ||
                foldForSearch(r.game.fileName).contains(q),
          )
          .take(_resultLimit)
          .toList();
    } catch (_) {
      _allGamesFuture = null;
      rethrow;
    }
  }

  Future<List<GameSearchResult>> _fetchAllGames(GamesApi gamesApi) async {
    final libraries = await gamesApi.getLibraries();
    final perLibrary = await Future.wait(
      libraries.map((library) async {
        final games = await gamesApi.getGames(library.id);
        return games.map(
          (game) => GameSearchResult(libraryId: library.id, game: game),
        );
      }),
    );
    return perLibrary.expand((results) => results).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    _work?.cancel();
    _generation++;
    _inputSpan?.end(outcome: 'disposed');
    PerformanceTrace.disposed(this, 'search');
    _debounceTimer?.cancel();
    super.dispose();
  }
}
