import 'package:dio/dio.dart';

import '../cache/cache_policy.dart';
import '../retry/retry_policy.dart';
import '../auth/token_refresher.dart';
import '../batch/batch_config.dart';

/// Central configuration object for SmartNetworkClient.
///
/// Create ONE instance and pass it to [SmartNetworkClient.initialize].
///
/// Example:
/// ```dart
/// final config = SmartConfig(
///   baseUrl: 'https://api.example.com',
///   retryPolicy: RetryPolicy(maxAttempts: 3),
///   cachePolicy: CachePolicy(maxAge: Duration(minutes: 10)),
///   tokenRefresher: MyTokenRefresher(),
/// );
/// await SmartNetworkClient().initialize(config);
/// ```
class SmartConfig {
  /// The base URL prepended to every request path.
  final String baseUrl;

  /// Timeout for establishing a connection (default: 30 seconds).
  final Duration connectTimeout;

  /// Timeout for receiving a response (default: 30 seconds).
  final Duration receiveTimeout;

  /// Timeout for sending a request body (default: 30 seconds).
  final Duration sendTimeout;

  /// Default headers merged into every request.
  final Map<String, dynamic> defaultHeaders;

  /// Controls automatic retry behaviour on failure.
  final RetryPolicy retryPolicy;

  /// Controls caching strategy and TTL.
  final CachePolicy cachePolicy;

  /// Enables offline request queuing (default: true).
  ///
  /// When [true] and a request has `extra['queueIfOffline'] = true`,
  /// the request is persisted to disk and replayed on reconnect.
  final bool enableOfflineMode;

  /// Prevents duplicate in-flight GET requests (default: true).
  ///
  /// If two identical GET requests fire simultaneously, only one HTTP
  /// call is made; both callers receive the same result.
  final bool enableDeduplication;

  /// Provide a [TokenRefresher] to enable automatic JWT refresh.
  ///
  /// Set to `null` if your API requires no authentication.
  final TokenRefresher? tokenRefresher;

  /// Enables request batching via a dedicated batch endpoint.
  ///
  /// Set to `null` to disable batching.
  final BatchConfig? batchConfig;

  /// Enables structured console logging (default: true).
  final bool enableLogging;

  /// Additional Dio interceptors appended after all built-in ones.
  final List<Interceptor> extraInterceptors;

  /// Name of the Hive box used for cache storage.
  final String cacheBoxName;

  /// Name of the Hive box used for offline queue storage.
  final String offlineQueueBoxName;

  const SmartConfig({
    required this.baseUrl,
    this.connectTimeout = const Duration(seconds: 30),
    this.receiveTimeout = const Duration(seconds: 30),
    this.sendTimeout = const Duration(seconds: 30),
    this.defaultHeaders = const {},
    this.retryPolicy = const RetryPolicy(),
    this.cachePolicy = const CachePolicy(),
    this.enableOfflineMode = true,
    this.enableDeduplication = true,
    this.tokenRefresher,
    this.batchConfig,
    this.enableLogging = true,
    this.extraInterceptors = const [],
    this.cacheBoxName = 'smart_network_cache',
    this.offlineQueueBoxName = 'smart_network_offline_queue',
  });

  /// Creates a copy of this config with the given fields replaced.
  SmartConfig copyWith({
    String? baseUrl,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, dynamic>? defaultHeaders,
    RetryPolicy? retryPolicy,
    CachePolicy? cachePolicy,
    bool? enableOfflineMode,
    bool? enableDeduplication,
    TokenRefresher? tokenRefresher,
    BatchConfig? batchConfig,
    bool? enableLogging,
    List<Interceptor>? extraInterceptors,
    String? cacheBoxName,
    String? offlineQueueBoxName,
  }) {
    return SmartConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      sendTimeout: sendTimeout ?? this.sendTimeout,
      defaultHeaders: defaultHeaders ?? this.defaultHeaders,
      retryPolicy: retryPolicy ?? this.retryPolicy,
      cachePolicy: cachePolicy ?? this.cachePolicy,
      enableOfflineMode: enableOfflineMode ?? this.enableOfflineMode,
      enableDeduplication: enableDeduplication ?? this.enableDeduplication,
      tokenRefresher: tokenRefresher ?? this.tokenRefresher,
      batchConfig: batchConfig ?? this.batchConfig,
      enableLogging: enableLogging ?? this.enableLogging,
      extraInterceptors: extraInterceptors ?? this.extraInterceptors,
      cacheBoxName: cacheBoxName ?? this.cacheBoxName,
      offlineQueueBoxName: offlineQueueBoxName ?? this.offlineQueueBoxName,
    );
  }

  @override
  String toString() => 'SmartConfig(baseUrl: $baseUrl, '
      'retry: ${retryPolicy.maxAttempts} attempts, '
      'cache: ${cachePolicy.strategy.name}, '
      'offline: $enableOfflineMode, '
      'dedup: $enableDeduplication, '
      'auth: ${tokenRefresher != null}, '
      'batch: ${batchConfig != null})';
}
