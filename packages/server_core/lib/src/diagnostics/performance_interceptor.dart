import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'performance_trace.dart';

/// Captures total client-observed time, including response transformation.
/// URLs, query parameters, headers and response bodies never reach the sink.
class PerformanceInterceptor extends Interceptor {
  static const _key = 'moonfin.performance.span';
  static const _headersKey = 'moonfin.performance.headersUs';
  static final _segments = <String>{
    'items',
    'users',
    'views',
    'playbackinfo',
    'playback',
    'bitratetest',
    'sessions',
    'playing',
    'progress',
    'stopped',
    'resume',
    'nextup',
    'shows',
    'seasons',
    'episodes',
    'ancestors',
    'intros',
    'similar',
    'images',
    'primary',
    'backdrop',
    'logo',
    'persons',
    'genres',
    'livetv',
    'channels',
    'programs',
    'recordings',
    'system',
    'info',
    'public',
    'library',
    'virtualfolders',
    'displaypreferences',
    'videos',
    'stream',
    'master.m3u8',
    'subtitles',
    'hls',
    'audio',
    'clientlog',
    'document',
    'search',
    'discover',
    'movie',
    'tv',
    'media',
    'request',
    'user',
    'settings',
    'trending',
    'popular',
    'games',
    'api',
    'v1',
    'v2',
    'emby',
    'jellyfin',
    'home',
    'startup',
    'details',
    'item',
    'video',
    'player',
    'diagnostics',
    'collections',
    'favorites',
    'downloads',
    'live-tv',
    'video-player',
    'libraries',
    'browse',
    'seerr',
    'music',
    'unknown',
  };

  static String endpoint(Uri uri) =>
      '/${uri.pathSegments.take(8).map((part) {
        final lower = part.toLowerCase();
        return _segments.contains(lower) ? lower : ':id';
      }).join('/')}';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (PerformanceTrace.enabled) {
      // Equality aliases are local to one recording. Credentials are excluded
      // even from the in-memory key; no key or parameter value reaches the sink.
      final parameters =
          Map<String, dynamic>.from(options.uri.queryParametersAll)
            ..removeWhere(
              (key, _) => RegExp(
                r'token|key|auth|password',
                caseSensitive: false,
              ).hasMatch(key),
            );
      final keys = parameters.keys.toList()..sort();
      final read = options.method == 'GET' || options.method == 'HEAD';
      // The interceptor belongs to this client/session. Header credential
      // changes separate scopes without retaining the credential in alias keys.
      final scope = PerformanceTrace.resource(this);
      final session = options.headers.entries
          .where(
            (e) => RegExp(
              r'authorization|x-emby-token',
              caseSensitive: false,
            ).hasMatch(e.key),
          )
          .map((e) => e.value.hashCode)
          .join(':');
      final alias = read
          ? PerformanceTrace.alias(
              jsonEncode([
                scope,
                session,
                options.method,
                options.uri.origin,
                options.uri.path,
                for (final key in keys) [key, parameters[key]],
              ]),
            )
          : null;
      options.extra[_key] = PerformanceTrace.begin('http.request', {
        'method': options.method,
        'endpoint': endpoint(options.uri),
        'server': PerformanceTrace.alias(options.uri.origin),
        'retry': options.extra['moonfin.connectionRetry'] == true,
        'requestAlias': alias,
        'parameterCount': keys.length,
        'streamed': options.responseType == ResponseType.stream,
        'callerCancellation': options.cancelToken != null,
        'connectTimeoutMs': options.connectTimeout?.inMilliseconds,
        'receiveTimeoutMs': options.receiveTimeout?.inMilliseconds,
        if (options.uri.pathSegments.any((s) => s.startsWith('tmdb:')))
          'idKind': 'tmdb_synthetic',
      });
    }
    handler.next(options);
  }

  static PerformanceSpan? span(RequestOptions options) =>
      options.extra[_key] as PerformanceSpan?;

  static void headersReceived(RequestOptions options) {
    final timing = span(options);
    if (timing != null) options.extra[_headersKey] = timing.elapsedUs;
  }

  static void _afterHeaders(RequestOptions options) {
    final headers = options.extra.remove(_headersKey);
    final timing = span(options);
    if (headers is int && timing != null) {
      // Stream responses are handed to the caller without draining their body.
      timing.mark(
        options.responseType == ResponseType.stream
            ? 'http.stream_handoff'
            : 'http.body_and_transform',
        {'durationUs': timing.elapsedUs - headers},
      );
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _afterHeaders(response.requestOptions);
    span(response.requestOptions)?.end(
      data: {
        'status': response.statusCode,
        'endpoint': endpoint(response.requestOptions.uri),
        'method': response.requestOptions.method,
        if (response.data is List) 'items': (response.data as List).length,
        if (response.data is Map && response.data['Items'] is List)
          'items': (response.data['Items'] as List).length,
      },
    );
    response.requestOptions.extra.remove(_key);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _afterHeaders(err.requestOptions);
    span(err.requestOptions)?.end(
      outcome: err.type.name,
      data: {
        'status': err.response?.statusCode,
        'endpoint': endpoint(err.requestOptions.uri),
        'method': err.requestOptions.method,
      },
    );
    err.requestOptions.extra.remove(_key);
    handler.next(err);
  }
}

/// Adds timing to an existing adapter without changing its connections,
/// cancellation, certificates, buffering or response stream.
class PerformanceTimingAdapter implements HttpClientAdapter {
  PerformanceTimingAdapter(this.inner);
  final HttpClientAdapter inner;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final span = PerformanceInterceptor.span(options);
    final dispatched = span?.elapsedUs;
    span?.mark('http.dispatched', {
      'durationUs': 0,
      'adapterQueueKnown': false,
    });
    try {
      final body = await inner.fetch(options, requestStream, cancelFuture);
      PerformanceInterceptor.headersReceived(options);
      span?.mark('http.headers', {
        'status': body.statusCode,
        'durationUs': span.elapsedUs - dispatched!,
      });
      return body;
    } catch (_) {
      span?.mark('http.adapter_error');
      rethrow;
    }
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
}
