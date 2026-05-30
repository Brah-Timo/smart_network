import 'dart:async';
import 'package:dio/dio.dart';

import '../deduplication/request_deduplicator.dart';
import '../deduplication/pending_request.dart';
import '../utils/logger.dart';

/// Prevents redundant in-flight GET requests from reaching the network.
///
/// When two (or more) identical GET requests are dispatched concurrently:
/// - The **first** request is sent normally; a [PendingRequest] is registered.
/// - Subsequent requests with the same fingerprint **wait** for the first
///   request to finish and receive its result — no extra HTTP call is made.
///
/// ### Request fingerprint
/// The key is: `METHOD:path?sorted_query_params`
///
/// ### Scope
/// Only GET requests are deduplicated. POST / PUT / DELETE / PATCH are always
/// sent as separate requests (they have side effects).
///
/// ### Per-request opt-out
/// Set `extra['deduplicate'] = false` on a [SmartRequest] to bypass.
class DedupInterceptor extends Interceptor {
  final RequestDeduplicator _deduplicator;
  final SmartLogger _logger;

  DedupInterceptor({
    required RequestDeduplicator deduplicator,
    SmartLogger? logger,
  })  : _deduplicator = deduplicator,
        _logger = logger ?? SmartLogger();

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Only deduplicate GETs; skip if caller opts out
    if (options.method != 'GET') return handler.next(options);
    final deduplicate = options.extra['deduplicate'] as bool? ?? true;
    if (!deduplicate) return handler.next(options);

    final key = _buildKey(options);

    // ── Is there already an in-flight request with this key? ─────────────────
    final pending = _deduplicator.getPending(key);
    if (pending != null) {
      _logger.d(
        '🔀 Dedup HIT — waiting for in-flight request: $key '
        '(age: ${pending.age.inMilliseconds}ms)',
      );

      try {
        final response = await pending.completer.future;
        // Return a cloned response with the current options so that
        // Dio's response handlers process it in the right context.
        return handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            data: response.data,
            statusCode: response.statusCode,
            statusMessage: response.statusMessage,
            headers: response.headers,
            extra: Map<String, dynamic>.from(response.extra)
              ..['dedupHit'] = true,
          ),
        );
      } on DioException catch (e) {
        return handler.reject(
          e.copyWith(requestOptions: options),
        );
      } catch (e, st) {
        return handler.reject(
          DioException(
            requestOptions: options,
            error: e,
            stackTrace: st,
          ),
        );
      }
    }

    // ── First request — register it and pass through ──────────────────────────
    _logger.d('🆕 Dedup REGISTER — key: $key');
    _deduplicator.addPending(key, PendingRequest(completer: Completer()));
    options.extra['dedupKey'] = key;

    return handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final key = response.requestOptions.extra['dedupKey'] as String?;
    if (key != null) {
      _logger.d('✅ Dedup RESOLVE — key: $key '
          '(status: ${response.statusCode})');
      _deduplicator.complete(key, response);
    }
    handler.next(response);
  }

  @override
  void onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) {
    final key = err.requestOptions.extra['dedupKey'] as String?;
    if (key != null) {
      _logger.w('❌ Dedup REJECT — key: $key');
      _deduplicator.completeError(key, err, err.stackTrace);
    }
    handler.next(err);
  }

  // ── Private Helpers ───────────────────────────────────────────────────────

  String _buildKey(RequestOptions options) {
    final params = options.queryParameters;
    final sortedKeys = params.keys.toList()..sort();
    final query = sortedKeys.map((k) => '$k=${params[k]}').join('&');
    return '${options.method}:${options.path}'
        '${query.isNotEmpty ? '?$query' : ''}';
  }
}
