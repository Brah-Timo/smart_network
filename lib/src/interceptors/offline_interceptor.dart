import 'package:dio/dio.dart';

import '../offline/offline_queue.dart';
import '../offline/offline_entry.dart';
import '../offline/connectivity_monitor.dart';
import '../utils/logger.dart';

/// Intercepts requests when the device is offline.
///
/// ### Behaviour
/// When no connectivity is detected:
///
/// - **Queueable requests** (`extra['queueIfOffline'] = true`):
///   The request is serialised to [OfflineQueue] and the caller receives
///   a synthetic 202 response: `{ "queued": true }`.
///   [QueueProcessor] will replay it on reconnect.
///
/// - **Non-queueable requests** (default for GET):
///   A [DioException] with type [DioExceptionType.connectionError] is
///   rejected immediately. The caller should handle this by showing
///   an appropriate offline UI.
///
/// ### Queueable vs non-queueable
/// Only idempotent-safe writes (POST, PUT, DELETE, PATCH) that the caller
/// explicitly opts into via `extra['queueIfOffline'] = true` are queued.
/// GET requests are served from cache by [CacheInterceptor] before
/// reaching this interceptor.
class OfflineInterceptor extends Interceptor {
  final OfflineQueue _queue;
  final ConnectivityMonitor _monitor;
  final SmartLogger _logger;

  OfflineInterceptor({
    required OfflineQueue queue,
    required ConnectivityMonitor monitor,
    SmartLogger? logger,
  })  : _queue = queue,
        _monitor = monitor,
        _logger = logger ?? SmartLogger();

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Fast path: device is online
    final connected = await _monitor.isConnected;
    if (connected) return handler.next(options);

    // ── Offline path ─────────────────────────────────────────────────────────
    final queueIfOffline =
        options.extra['queueIfOffline'] as bool? ?? false;

    if (queueIfOffline) {
      await _queue.enqueue(OfflineEntry.fromRequestOptions(options));

      _logger.w(
        '📵 Offline — request queued for later: '
        '${options.method} ${options.path}',
      );

      // Return a 202 Accepted to inform the caller it was queued
      return handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 202,
          statusMessage: 'Accepted (queued for offline sync)',
          data: <String, dynamic>{
            'queued': true,
            'message':
                'No internet connection. Your request has been saved and '
                'will be sent automatically when you\'re back online.',
          },
          extra: const {'isQueued': true},
        ),
      );
    }

    // Not queueable — reject with a clear offline error
    _logger.w(
      '📵 Offline — rejecting request: ${options.method} ${options.path}',
    );

    return handler.reject(
      DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'No internet connection.',
      ),
    );
  }
}
