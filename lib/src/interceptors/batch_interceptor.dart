import 'package:dio/dio.dart';

import '../batch/batch_processor.dart';
import '../utils/logger.dart';

/// Optional interceptor that routes requests tagged with
/// `extra['batch'] = true` through [BatchProcessor].
///
/// This is an alternative to calling [BatchProcessor.addRequest] directly —
/// it lets you mark individual requests for batching at the call site:
///
/// ```dart
/// await client.get(
///   '/users/1',
///   options: Options(extra: {'batch': true}),
/// );
/// ```
///
/// Batched requests are resolved synchronously once the batch completes.
class BatchInterceptor extends Interceptor {
  final BatchProcessor _processor;
  final SmartLogger _logger;

  BatchInterceptor({
    required BatchProcessor processor,
    SmartLogger? logger,
  })  : _processor = processor,
        _logger = logger ?? SmartLogger();

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final isBatched = options.extra['batch'] as bool? ?? false;
    if (!isBatched) return handler.next(options);

    _logger.d('📦 Routing to BatchProcessor: ${options.method} ${options.path}');

    try {
      final result = await _processor.addRequest<dynamic>(
        path: options.path,
        method: options.method,
        data: options.data,
        queryParameters: options.queryParameters,
      );

      return handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          data: result,
          statusCode: 200,
          extra: const {'batched': true},
        ),
      );
    } catch (e) {
      return handler.reject(
        DioException(
          requestOptions: options,
          error: e,
          message: 'Batch request failed: $e',
        ),
      );
    }
  }
}
