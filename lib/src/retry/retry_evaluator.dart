import 'package:dio/dio.dart';
import 'retry_policy.dart';

/// Decides whether a failed [DioException] should be retried given the
/// current [RetryPolicy] and the number of attempts already made.
///
/// Extracted from [RetryInterceptor] so it can be unit-tested independently
/// and swapped out for custom evaluation logic.
class RetryEvaluator {
  final RetryPolicy policy;

  const RetryEvaluator(this.policy);

  /// Returns `true` when the request should be retried.
  ///
  /// Parameters:
  /// - [error]          — the exception from the most recent attempt
  /// - [currentAttempt] — number of attempts already made (0-based; the
  ///                       initial request counts as attempt 0)
  /// - [allowRetry]     — per-request override flag from `extra['allowRetry']`
  bool shouldRetry(
    DioException error,
    int currentAttempt, {
    bool allowRetry = true,
  }) {
    // Hard stops
    if (!allowRetry) return false;
    if (currentAttempt >= policy.maxAttempts) return false;

    final statusCode = error.response?.statusCode;

    // Explicit do-not-retry list wins over everything else
    if (statusCode != null &&
        policy.doNotRetryOnStatusCodes.contains(statusCode)) {
      return false;
    }

    // Connection-level error (no HTTP response received at all)
    if (error.type == DioExceptionType.connectionError && statusCode == null) {
      return policy.retryOnConnectionError;
    }

    // Timeout errors
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return policy.retryOnTimeout;
    }

    // HTTP error response
    if (statusCode != null) {
      return policy.retryOnStatusCodes.contains(statusCode);
    }

    return false;
  }
}
