import 'package:dio/dio.dart';
import 'performance_trace.dart';

/// Captures total client-observed time, including response transformation.
/// URLs, query parameters, headers and response bodies never reach the sink.
class PerformanceInterceptor extends Interceptor {
  static const _key = 'moonfin.performance.span';
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
      options.extra[_key] = PerformanceTrace.begin('http.request', {
        'method': options.method,
        'endpoint': endpoint(options.uri),
        'server': PerformanceTrace.alias(options.uri.origin),
        'retry': options.extra['moonfin.connectionRetry'] == true,
      });
    }
    handler.next(options);
  }

  static PerformanceSpan? span(RequestOptions options) =>
      options.extra[_key] as PerformanceSpan?;

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    span(response.requestOptions)?.end(
      data: {
        'status': response.statusCode,
        'endpoint': endpoint(response.requestOptions.uri),
        'method': response.requestOptions.method,
        if (response.data is List) 'items': (response.data as List).length,
      },
    );
    response.requestOptions.extra.remove(_key);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
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
