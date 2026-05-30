import 'package:equatable/equatable.dart';
import 'backoff_strategy.dart';

/// Defines when and how [SmartNetworkClient] retries failed requests.
///
/// Pass a [RetryPolicy] to [SmartConfig.retryPolicy] to configure
/// retry behaviour globally. Override per-request by setting
/// `extra['allowRetry'] = false` on individual [SmartRequest]s.
///
/// Example:
/// ```dart
/// RetryPolicy(
///   maxAttempts: 4,
///   retryOnStatusCodes: {408, 500, 502, 503, 504},
///   backoffStrategy: ExponentialBackoff(
///     base: Duration(seconds: 1),
///     maxDelay: Duration(seconds: 20),
///   ),
/// )
/// ```
class RetryPolicy extends Equatable {
  /// Maximum number of retry attempts after the initial failure.
  ///
  /// Total requests made = 1 (initial) + [maxAttempts].
  /// Default: 3.
  final int maxAttempts;

  /// HTTP status codes that trigger a retry.
  ///
  /// Default: `{408, 500, 502, 503, 504}`.
  ///
  /// - 408 Request Timeout
  /// - 500 Internal Server Error
  /// - 502 Bad Gateway
  /// - 503 Service Unavailable
  /// - 504 Gateway Timeout
  final Set<int> retryOnStatusCodes;

  /// Retry on [DioExceptionType.connectionError] (default: true).
  final bool retryOnConnectionError;

  /// Retry on connect / send / receive timeout (default: true).
  final bool retryOnTimeout;

  /// Do NOT retry when the server returns one of these status codes,
  /// even if [retryOnStatusCodes] would otherwise match.
  ///
  /// Takes precedence over [retryOnStatusCodes].
  final Set<int> doNotRetryOnStatusCodes;

  /// The delay strategy used between attempts.
  ///
  /// Default: [ExponentialBackoff] with 1 s base and 30 s cap.
  final BackoffStrategy backoffStrategy;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.retryOnStatusCodes = const {408, 500, 502, 503, 504},
    this.retryOnConnectionError = true,
    this.retryOnTimeout = true,
    this.doNotRetryOnStatusCodes = const {},
    this.backoffStrategy = const ExponentialBackoff(),
  });

  /// A policy that disables all retries.
  static const none = RetryPolicy(maxAttempts: 0);

  /// A policy optimised for idempotent read operations.
  static const aggressive = RetryPolicy(
    maxAttempts: 5,
    retryOnStatusCodes: {408, 429, 500, 502, 503, 504},
    backoffStrategy: ExponentialBackoff(
      base: Duration(milliseconds: 500),
      maxDelay: Duration(seconds: 60),
    ),
  );

  @override
  List<Object?> get props => [
        maxAttempts,
        retryOnStatusCodes,
        retryOnConnectionError,
        retryOnTimeout,
        doNotRetryOnStatusCodes,
      ];

  @override
  String toString() => 'RetryPolicy('
      'maxAttempts: $maxAttempts, '
      'codes: $retryOnStatusCodes, '
      'strategy: $backoffStrategy)';
}
