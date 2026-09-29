import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../diagnostics/server_log_sink.dart';
import '../diagnostics/performance_interceptor.dart';
import 'server_user_agent.dart';
import 'request_work_scope.dart';
import 'scheduled_http_adapter.dart';

/// How many requests may be reaching the server at once.
///
/// dart:io speaks HTTP/1.1 with no ALPN, so every request in flight is its own
/// TCP and TLS handshake, where a browser multiplexes a whole screen over one
/// HTTP/2 connection. Six is what a browser allows itself per host without
/// multiplexing, and it keeps a screen from opening a burst that a reverse
/// proxy reads as a flood.
const _requestSlots = 6;

/// How long a connection may sit unused before the pool drops it.
///
/// dart:io hands out a pooled connection without checking it is still open, so
/// the longer one is held the better the odds the peer let go of it in the
/// meantime. Anything on screen keeps the pool warm inside this, and playback
/// reports progress every five seconds.
const _idleTimeout = Duration(seconds: 15);

void configureServerDio(Dio dio, {Duration? idleTimeout}) {
  dio.interceptors.add(RequestScopeInterceptor());
  dio.interceptors.add(PerformanceInterceptor());
  dio.transformer = FusedTransformer(contentLengthIsolateThreshold: 50 * 1024);

  dio.httpClientAdapter = ScheduledHttpAdapter(
    IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();

        client.userAgent = serverUserAgent;

        client.badCertificateCallback = (_, _, _) => true;

        client.idleTimeout = idleTimeout ?? _idleTimeout;

        // Deliberately above the slot count. A slot frees as soon as the
        // headers land but dart:io keeps the connection until the body has
        // drained, so matching the two sends the overflow into a queue inside
        // dart:io that nothing times out and Dio bills to its connect timeout.
        client.maxConnectionsPerHost = _requestSlots * 2;

        return client;
      },
    ),
    slots: _requestSlots,
  );

  dio.interceptors.add(_retryDeadConnection(dio));
}

const _retriedKey = 'moonfin.connectionRetry';

/// Asks again on a fresh connection when a pooled one died before answering.
///
/// dart:io reuses an idle connection without checking it is still alive, so a
/// socket the peer let go of is written to and only fails once TCP gives up,
/// which on a phone is around eighteen seconds. The failure takes that
/// connection out of the pool, so one more try is all it takes and a second
/// failure is a different problem.
Interceptor _retryDeadConnection(Dio dio) => InterceptorsWrapper(
  onError: (e, handler) async {
    final options = e.requestOptions;
    // A half received response surfaces as a parse failure rather than a
    // socket error, which is what keeps work the server already did out of
    // the retry.
    final connectionDied =
        e.type == DioExceptionType.unknown &&
        (e.error is HttpException || e.error is SocketException);

    // Only a read can go out a second time without changing anything.
    if (!connectionDied ||
        options.extra[_retriedKey] == true ||
        options.method.toUpperCase() != 'GET') {
      handler.next(e);
      return;
    }

    options.extra[_retriedKey] = true;
    ServerLog.network(
      'Connection died before answering, asking again: '
      '${options.method} ${options.uri}',
      level: ServerLogLevel.warning,
      error: e.error,
    );

    try {
      handler.resolve(await dio.fetch(options));
    } on DioException catch (retryFailure) {
      // The second attempt ran the whole chain, so it reported itself.
      handler.reject(retryFailure);
    }
  },
);
