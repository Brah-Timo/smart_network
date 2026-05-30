import 'package:dio/dio.dart';

import '../retry/retry_policy.dart';
import '../retry/retry_evaluator.dart';
import '../utils/logger.dart';

/// Intercepts [DioException]s and automatically retries the request
/// according to the configured [RetryPolicy].
///
/// ### Retry flow
/// ```
/// onError(err)
///   └─ RetryEvaluator.shouldRetry?
///        ├─ NO  → forward error to next interceptor
///        └─ YES → wait BackoffStrategy.calculate(attempt)
///                  → dio.fetch(originalRequest)
///                       ├─ success → resolve response
///                       └─ error   → recurse (increment attempt)
/// ```
///
/// The current attempt count is stored in [RequestOptions.extra] under
/// the key `'retryAttempt'` so it survives across the interceptor chain.
class RetryInterceptor extends Interceptor {
  final Dio _dio;
  final RetryPolicy _policy;
  final RetryEvaluator _evaluator;
  final SmartLogger _logger;

  RetryInterceptor({
    required Dio dio,
    required RetryPolicy policy,
    SmartLogger? logger,
  })  : _dio = dio,
        _policy = policy,
        _evaluator = RetryEvaluator(policy),
        _logger = logger ?? SmartLogger();

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;

    // Read current attempt from extra (0 = first failure after initial call)
    final currentAttempt = (options.extra['retryAttempt'] as int?) ?? 0;
    final allowRetry = options.extra['allowRetry'] as bool? ?? true;

    if (!_evaluator.shouldRetry(err, currentAttempt, allowRetry: allowRetry)) {
      _logger.d('⛔ No more retries for ${options.method} ${options.path} '
          '(attempt $currentAttempt/${_policy.maxAttempts})');
      return handler.next(err);
    }

    // Calculate wait time for this attempt
    final delay = _policy.backoffStrategy.calculate(currentAttempt);

    _logger.w(
      '🔁 Retry ${currentAttempt + 1}/${_policy.maxAttempts} '
      'for ${options.method} ${options.path} — '
      'waiting ${delay.inMilliseconds} ms '
      '(${_policy.backoffStrategy})',
    );

    await Future<void>.delayed(delay);

    // Stamp the updated attempt count before re-dispatching
    final retryOptions = options.copyWith(
      extra: Map<String, dynamic>.from(options.extra)
        ..['retryAttempt'] = currentAttempt + 1,
    );

    try {
      _logger.d('📤 Re-dispatching ${retryOptions.method} ${retryOptions.path}');
      final response = await _dio.fetch<dynamic>(retryOptions);
      _logger.i(
        '✅ Retry succeeded for ${retryOptions.path} '
        '(status ${response.statusCode})',
      );
      return handler.resolve(response);
    } on DioException catch (retryError) {
      // Let the error bubble back through onError for the next attempt
      return handler.next(retryError);
    }
  }
}
