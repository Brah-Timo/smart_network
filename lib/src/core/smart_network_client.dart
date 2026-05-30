import 'package:dio/dio.dart';

import 'smart_config.dart';
import 'smart_request.dart';
import 'smart_response.dart';
import 'smart_exception.dart';
import '../cache/memory_cache.dart';
import '../cache/hive_cache.dart';
import '../interceptors/retry_interceptor.dart';
import '../interceptors/cache_interceptor.dart';
import '../interceptors/dedup_interceptor.dart';
import '../interceptors/offline_interceptor.dart';
import '../interceptors/auth_interceptor.dart';
import '../interceptors/batch_interceptor.dart';
import '../deduplication/request_deduplicator.dart';
import '../offline/offline_queue.dart';
import '../offline/connectivity_monitor.dart';
import '../offline/queue_processor.dart';
import '../auth/token_manager.dart';
import '../auth/token_refresher.dart';
import '../batch/batch_processor.dart';
import '../utils/logger.dart';

/// The primary entry point for SmartNetwork.
///
/// Use as a **singleton** — call [initialize] once in `main()`, then
/// access the same instance via `SmartNetworkClient()` anywhere in your
/// app (factory constructor returns the shared instance).
///
/// ### Minimal setup
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await SmartNetworkClient().initialize(
///     SmartConfig(baseUrl: 'https://api.example.com'),
///   );
///   runApp(const MyApp());
/// }
/// ```
///
/// ### Interceptor execution order (onRequest: top → bottom)
/// ```
/// 1. LogInterceptor       — records every request & response
/// 2. AuthInterceptor      — injects Bearer token, handles 401 refresh
/// 3. CacheInterceptor     — serves/stores responses in memory + Hive
/// 4. DedupInterceptor     — collapses duplicate in-flight GETs
/// 5. BatchInterceptor     — routes batch-tagged requests to BatchProcessor
/// 6. OfflineInterceptor   — queues/rejects requests when offline
/// 7. RetryInterceptor     — retries on transient errors (onError)
/// 8. extraInterceptors    — user-supplied additions
/// ```
class SmartNetworkClient {
  // ── Singleton ─────────────────────────────────────────────────────────────
  static SmartNetworkClient? _instance;
  SmartNetworkClient._();

  factory SmartNetworkClient() {
    _instance ??= SmartNetworkClient._();
    return _instance!;
  }

  // ── Internal state ────────────────────────────────────────────────────────
  late Dio _dio;
  late SmartConfig _config;
  late SmartLogger _logger;
  late MemoryCache _memCache;
  late HiveCache _hiveCache;
  late OfflineQueue _offlineQueue;
  late ConnectivityMonitor _connectivityMonitor;
  late QueueProcessor _queueProcessor;
  BatchProcessor? _batchProcessor;
  TokenManager? _tokenManager;
  bool _initialised = false;

  // ── Initialisation ────────────────────────────────────────────────────────

  /// Initialises the client with the given [config].
  ///
  /// Must be called (and awaited) exactly **once** before making any requests.
  /// Calling it a second time resets the client with the new configuration.
  Future<void> initialize(SmartConfig config) async {
    // Clean up any previous state on re-initialisation
    if (_initialised) await dispose();

    _config = config;
    _logger = SmartLogger(enabled: config.enableLogging);
    _logger.i('🚀 Initialising SmartNetworkClient...');
    _logger.d('Config: $config');

    // ── 1. Persistent Cache (Hive) ────────────────────────────────────────
    _hiveCache = HiveCache(boxName: config.cacheBoxName);
    await _hiveCache.initialize();
    _memCache = MemoryCache(maxEntries: config.cachePolicy.maxMemoryEntries);

    // ── 2. Offline Queue ──────────────────────────────────────────────────
    _offlineQueue = OfflineQueue(
      hiveCache: _hiveCache,
      namespace: config.offlineQueueBoxName,
    );

    // ── 3. Auth Token Manager ─────────────────────────────────────────────
    if (config.tokenRefresher != null) {
      _tokenManager = TokenManager(
        refresher: config.tokenRefresher!,
        logger: _logger,
      );
    }

    // ── 4. Core Dio Instance ──────────────────────────────────────────────
    _dio = Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        sendTimeout: config.sendTimeout,
        headers: <String, dynamic>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ...config.defaultHeaders,
        },
      ),
    );

    // ── 5. Batch Processor ────────────────────────────────────────────────
    if (config.batchConfig != null) {
      _batchProcessor = BatchProcessor(
        dio: _dio,
        config: config.batchConfig!,
        logger: _logger,
      );
    }

    // ── 6. Connectivity Monitor ───────────────────────────────────────────
    _connectivityMonitor = ConnectivityMonitor();
    _queueProcessor = QueueProcessor(
      queue: _offlineQueue,
      dio: _dio,
      baseUrl: config.baseUrl,
      logger: _logger,
    );

    // ── 7. Interceptor Chain ──────────────────────────────────────────────
    _buildInterceptorChain();

    // ── 8. Start Connectivity Monitor ────────────────────────────────────
    if (config.enableOfflineMode) {
      _connectivityMonitor.startMonitoring(
        onConnected: () {
          _logger.i('📡 Back online — processing offline queue...');
          _queueProcessor.processQueue();
        },
        onDisconnected: () => _logger.w('📵 Device went offline'),
      );
    }

    _initialised = true;
    _logger.i('✅ SmartNetworkClient ready.');
  }

  void _buildInterceptorChain() {
    _dio.interceptors.clear();

    // ── 1. Logging (always first — captures raw request/response) ──────────
    if (_config.enableLogging) {
      _dio.interceptors.add(
        LogInterceptor(
          requestBody: true,
          responseBody: true,
          requestHeader: false,
          responseHeader: false,
          error: true,
          logPrint: (object) => _logger.d(object.toString()),
        ),
      );
    }

    // ── 2. Auth ────────────────────────────────────────────────────────────
    if (_tokenManager != null) {
      _dio.interceptors.add(
        AuthInterceptor(
          tokenManager: _tokenManager!,
          dio: _dio,
          logger: _logger,
        ),
      );
    }

    // ── 3. Cache ───────────────────────────────────────────────────────────
    _dio.interceptors.add(
      CacheInterceptor(
        memoryCache: _memCache,
        hiveCache: _hiveCache,
        policy: _config.cachePolicy,
        dio: _dio,
        logger: _logger,
      ),
    );

    // ── 4. Deduplication ───────────────────────────────────────────────────
    if (_config.enableDeduplication) {
      _dio.interceptors.add(
        DedupInterceptor(
          deduplicator: RequestDeduplicator(),
          logger: _logger,
        ),
      );
    }

    // ── 5. Batch ───────────────────────────────────────────────────────────
    if (_batchProcessor != null) {
      _dio.interceptors.add(
        BatchInterceptor(
          processor: _batchProcessor!,
          logger: _logger,
        ),
      );
    }

    // ── 6. Offline ─────────────────────────────────────────────────────────
    if (_config.enableOfflineMode) {
      _dio.interceptors.add(
        OfflineInterceptor(
          queue: _offlineQueue,
          monitor: _connectivityMonitor,
          logger: _logger,
        ),
      );
    }

    // ── 7. Retry (last — handles errors from all previous interceptors) ────
    _dio.interceptors.add(
      RetryInterceptor(
        dio: _dio,
        policy: _config.retryPolicy,
        logger: _logger,
      ),
    );

    // ── 8. User-supplied extras ────────────────────────────────────────────
    _dio.interceptors.addAll(_config.extraInterceptors);

    _logger.d(
      '🔗 Interceptor chain: '
      '[Log → Auth → Cache → Dedup → Batch → Offline → Retry → Custom]',
    );
  }

  // ── Public HTTP API ───────────────────────────────────────────────────────

  /// Executes an HTTP GET request.
  Future<SmartResponse<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? fromJson,
    bool useCache = true,
    bool allowRetry = true,
    Duration? timeout,
  }) {
    return _execute<T>(
      SmartRequest(
        method: HttpMethod.get,
        path: path,
        queryParameters: queryParameters,
        headers: headers,
        useCache: useCache,
        allowRetry: allowRetry,
        timeout: timeout,
      ),
      fromJson: fromJson,
    );
  }

  /// Executes an HTTP POST request.
  Future<SmartResponse<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
    bool allowRetry = false, // writes are not retried by default
    Duration? timeout,
  }) {
    return _execute<T>(
      SmartRequest(
        method: HttpMethod.post,
        path: path,
        data: data,
        queryParameters: queryParameters,
        headers: headers,
        allowRetry: allowRetry,
        queueIfOffline: queueIfOffline,
        timeout: timeout,
      ),
      fromJson: fromJson,
    );
  }

  /// Executes an HTTP PUT request.
  Future<SmartResponse<T>> put<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
    bool allowRetry = false,
    Duration? timeout,
  }) {
    return _execute<T>(
      SmartRequest(
        method: HttpMethod.put,
        path: path,
        data: data,
        headers: headers,
        allowRetry: allowRetry,
        queueIfOffline: queueIfOffline,
        timeout: timeout,
      ),
      fromJson: fromJson,
    );
  }

  /// Executes an HTTP PATCH request.
  Future<SmartResponse<T>> patch<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
    bool allowRetry = false,
    Duration? timeout,
  }) {
    return _execute<T>(
      SmartRequest(
        method: HttpMethod.patch,
        path: path,
        data: data,
        headers: headers,
        allowRetry: allowRetry,
        queueIfOffline: queueIfOffline,
        timeout: timeout,
      ),
      fromJson: fromJson,
    );
  }

  /// Executes an HTTP DELETE request.
  Future<SmartResponse<T>> delete<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? headers,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
    bool allowRetry = false,
    Duration? timeout,
  }) {
    return _execute<T>(
      SmartRequest(
        method: HttpMethod.delete,
        path: path,
        data: data,
        headers: headers,
        allowRetry: allowRetry,
        queueIfOffline: queueIfOffline,
        timeout: timeout,
      ),
      fromJson: fromJson,
    );
  }

  /// Adds a request to the batch queue (requires [SmartConfig.batchConfig]).
  ///
  /// Throws [StateError] if batching is not configured.
  Future<T> batch<T>({
    required String path,
    required String method,
    dynamic data,
    Map<String, dynamic>? queryParameters,
    T Function(dynamic json)? fromJson,
  }) {
    if (_batchProcessor == null) {
      throw StateError(
        'Request batching is not enabled. '
        'Provide a BatchConfig in SmartConfig.batchConfig.',
      );
    }
    return _batchProcessor!.addRequest<T>(
      path: path,
      method: method,
      data: data,
      queryParameters: queryParameters,
      fromJson: fromJson,
    );
  }

  // ── Token Management ──────────────────────────────────────────────────────

  /// Stores [accessToken] and [refreshToken] in [TokenStorage].
  ///
  /// Call this after a successful login.
  Future<void> setTokens({
    required String accessToken,
    required String refreshToken,
    int? expiresIn,
  }) async {
    _assertInitialised();
    await _tokenManager?.saveTokens(
      TokenPair(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn,
      ),
    );
  }

  /// Clears all stored tokens.
  ///
  /// Call this on logout.
  Future<void> clearTokens() async {
    _assertInitialised();
    await _tokenManager?.clearTokens();
  }

  // ── Cache Management ──────────────────────────────────────────────────────

  /// Removes all entries from both cache layers.
  Future<void> clearCache() async {
    _assertInitialised();
    await _memCache.clear();
    await _hiveCache.clear();
    _logger.i('🗑️ Cache cleared');
  }

  /// Evicts all expired entries from both cache layers.
  /// Returns the total number of entries removed.
  Future<int> evictExpiredCache() async {
    _assertInitialised();
    final mem = await _memCache.evictExpired();
    final hive = await _hiveCache.evictExpired();
    _logger.i('🗑️ Evicted ${mem + hive} expired cache entries');
    return mem + hive;
  }

  // ── Offline Queue ─────────────────────────────────────────────────────────

  /// Manually triggers offline queue processing.
  Future<void> processOfflineQueue() async {
    _assertInitialised();
    await _queueProcessor.processQueue();
  }

  /// Returns the number of requests waiting in the offline queue.
  Future<int> get offlineQueueSize async {
    _assertInitialised();
    return _offlineQueue.pendingCount;
  }

  /// Clears all pending offline requests (use with caution).
  Future<void> clearOfflineQueue() async {
    _assertInitialised();
    await _offlineQueue.clear();
    _logger.w('🗑️ Offline queue cleared');
  }

  // ── Diagnostics ───────────────────────────────────────────────────────────

  /// Returns a snapshot of the current client state for debugging.
  Future<Map<String, dynamic>> diagnostics() async {
    _assertInitialised();
    return {
      'baseUrl': _config.baseUrl,
      'isInitialised': _initialised,
      'isOnline': await _connectivityMonitor.isConnected,
      'cacheEntries': {
        'memory': await _memCache.size,
        'hive': await _hiveCache.size,
      },
      'offlineQueueSize': await _offlineQueue.pendingCount,
      'batchPending': _batchProcessor?.pendingCount ?? 0,
      'interceptors': _config.enableDeduplication ? 'dedup+' : '' +
          (_config.enableOfflineMode ? 'offline+' : '') +
          (_tokenManager != null ? 'auth+' : '') +
          (_batchProcessor != null ? 'batch+' : '') +
          'retry',
    };
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Releases all resources held by this client.
  ///
  /// After calling [dispose], you must call [initialize] again before
  /// making any more requests.
  Future<void> dispose() async {
    if (!_initialised) return;
    _connectivityMonitor.stopMonitoring();
    _batchProcessor?.dispose();
    await _hiveCache.close();
    _dio.close(force: true);
    _initialised = false;
    _logger.i('👋 SmartNetworkClient disposed');
  }

  // ── Private Helpers ───────────────────────────────────────────────────────

  Future<SmartResponse<T>> _execute<T>(
    SmartRequest request, {
    T Function(dynamic json)? fromJson,
  }) async {
    _assertInitialised();

    try {
      final options = Options(
        method: request.method.value,
        headers: request.headers,
        receiveTimeout: request.timeout,
        extra: request.resolvedExtra,
      );

      final response = await _dio.request<dynamic>(
        request.path,
        data: request.data,
        queryParameters: request.queryParameters,
        options: options,
      );

      final T parsed;
      try {
        parsed = fromJson != null
            ? fromJson(response.data)
            : response.data as T;
      } catch (e) {
        throw SmartException.parseError(
          path: request.path,
          rawError: e,
        );
      }

      return SmartResponse<T>(
        data: parsed,
        statusCode: response.statusCode ?? 200,
        headers: response.headers.map,
        fromCache: response.extra['fromCache'] == true,
        isStale: response.extra['isStale'] == true,
        isQueued: response.extra['isQueued'] == true,
      );
    } on SmartException {
      rethrow;
    } on DioException catch (e) {
      throw SmartException.fromDioException(
        e,
        retryAttempts: e.requestOptions.extra['retryAttempt'] as int?,
      );
    } catch (e) {
      throw SmartException(
        message: 'Unexpected error: $e',
        type: SmartExceptionType.unknown,
        requestPath: request.path,
        rawError: e,
      );
    }
  }

  void _assertInitialised() {
    if (!_initialised) {
      throw StateError(
        'SmartNetworkClient is not initialised. '
        'Call await SmartNetworkClient().initialize(config) in main() first.',
      );
    }
  }

  // ── Accessors (for testing) ───────────────────────────────────────────────

  /// Exposes the underlying [Dio] instance — use for testing only.
  @visibleForTesting
  Dio get dioInstance => _dio;

  /// Exposes the [TokenManager] — use for testing only.
  @visibleForTesting
  TokenManager? get tokenManager => _tokenManager;

  SmartConfig get config => _config;
  bool get isInitialised => _initialised;

  @override
  String toString() => 'SmartNetworkClient('
      'url: ${_config.baseUrl}, '
      'ready: $_initialised)';
}

// ── visibleForTesting annotation (inline, no flutter dependency) ──────────────
const _VisibleForTesting visibleForTesting = _VisibleForTesting();

class _VisibleForTesting {
  const _VisibleForTesting();
}
