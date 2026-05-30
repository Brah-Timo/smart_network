# smart_network — API Reference

Complete reference for every public class, enum, and method.

---

## Table of Contents

- [SmartNetworkClient](#smartnetworkclient)
- [SmartConfig](#smartconfig)
- [SmartRequest](#smartrequest)
- [SmartResponse\<T\>](#smartresponset)
- [SmartException](#smartexception)
- [SmartExceptionType](#smartexceptiontype)
- [RetryPolicy](#retrypolicy)
- [BackoffStrategy](#backoffstrategy)
- [CachePolicy](#cachepolicy)
- [CacheStrategy](#cachestrategy)
- [CacheEntry](#cacheentry)
- [CacheKeyBuilder](#cachekeybuilder)
- [SmartCache](#smartcache)
- [MemoryCache](#memorycache)
- [HiveCache](#hivecache)
- [TokenPair](#tokenpair)
- [TokenRefresher](#tokenrefresher)
- [TokenStorage](#tokenstorage)
- [InMemoryTokenStorage](#inmemorytokenstorage)
- [TokenManager](#tokenmanager)
- [BatchConfig](#batchconfig)
- [BatchEntry](#batchentry)
- [BatchProcessor](#batchprocessor)
- [OfflineEntry](#offlineentry)
- [OfflineQueue](#offlinequeue)
- [ConnectivityMonitor](#connectivitymonitor)
- [QueueProcessor](#queueprocessor)
- [RequestDeduplicator](#requestdeduplicator)
- [SmartLogger](#smartlogger)
- [NetworkUtils](#networkutils)

---

## SmartNetworkClient

**Singleton entry point.** One instance per app. Call `initialize()` once in `main()`.

```dart
factory SmartNetworkClient()
```

### Methods

| Signature | Description |
|---|---|
| `Future<void> initialize(SmartConfig config)` | Bootstrap the client. Safe to call again — disposes previous state. |
| `Future<void> dispose()` | Tear down Hive, subscriptions, and processors. |
| `Future<SmartResponse<T>> get<T>(String path, {…})` | HTTP GET |
| `Future<SmartResponse<T>> post<T>(String path, {dynamic data, …})` | HTTP POST |
| `Future<SmartResponse<T>> put<T>(String path, {dynamic data, …})` | HTTP PUT |
| `Future<SmartResponse<T>> patch<T>(String path, {dynamic data, …})` | HTTP PATCH |
| `Future<SmartResponse<T>> delete<T>(String path, {…})` | HTTP DELETE |
| `Future<SmartResponse<T>> batch<T>({required String path, required String method, …})` | Enqueue to BatchProcessor |
| `Future<void> setTokens({required String accessToken, required String refreshToken, int? expiresIn})` | Store JWT pair after login |
| `Future<void> clearTokens()` | Remove stored tokens (logout) |
| `Future<void> clearCache()` | Wipe all L1 + L2 cache entries |
| `Future<void> evictExpiredCache()` | Remove only expired entries |
| `Future<void> clearOfflineQueue()` | Discard pending offline requests |
| `Future<void> processOfflineQueue()` | Force-replay offline queue immediately |
| `Future<Map<String, dynamic>> diagnostics()` | Live snapshot of internal state |

### Common optional parameters (all HTTP methods)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `fromJson` | `T Function(dynamic)?` | `null` | JSON → model deserialiser |
| `queryParameters` | `Map<String, dynamic>?` | `null` | URL query string |
| `headers` | `Map<String, String>?` | `null` | Extra request headers |
| `useCache` | `bool?` | from config | Override cache for this request |
| `allowRetry` | `bool?` | from config | Override retry for this request |
| `queueIfOffline` | `bool?` | from config | Queue when offline |
| `connectTimeout` | `Duration?` | from config | Per-request connect timeout |
| `receiveTimeout` | `Duration?` | from config | Per-request receive timeout |

---

## SmartConfig

**Immutable** central configuration. Pass to `initialize()`.

```dart
SmartConfig({
  required String baseUrl,
  Duration connectTimeout = const Duration(seconds: 10),
  Duration receiveTimeout = const Duration(seconds: 30),
  bool enableLogging = false,
  RetryPolicy retryPolicy = const RetryPolicy(),
  CachePolicy cachePolicy = const CachePolicy(),
  TokenRefresher? tokenRefresher,
  BatchConfig? batchConfig,
  List<Interceptor> extraInterceptors = const [],
  String cacheBoxName = 'smart_network_cache',
  String offlineQueueBoxName = 'smart_network_queue',
  Map<String, String> defaultHeaders = const {},
})
```

`copyWith()` is provided for all fields.

---

## SmartRequest

Internal model representing a single HTTP request. Exposed for interceptors.

| Field | Type | Description |
|---|---|---|
| `path` | `String` | Relative path (e.g. `/users/42`) |
| `method` | `String` | HTTP verb in UPPERCASE |
| `data` | `dynamic` | Request body |
| `queryParameters` | `Map<String, dynamic>?` | Query string |
| `headers` | `Map<String, String>?` | Extra headers |
| `useCache` | `bool` | Whether to consult cache |
| `allowRetry` | `bool` | Whether retry is permitted |
| `queueIfOffline` | `bool` | Whether to queue when offline |
| `uniqueKey` | `String` | Deduplication + cache key |

---

## SmartResponse\<T\>

Typed wrapper around Dio's raw response.

| Member | Type | Description |
|---|---|---|
| `data` | `T` | Parsed response body |
| `statusCode` | `int` | HTTP status code |
| `headers` | `Map<String, List<String>>` | Response headers |
| `fromCache` | `bool` | Served from L1/L2 cache |
| `isStale` | `bool` | Background SWR refresh is pending |
| `isQueued` | `bool` | Request was enqueued (offline) |
| `map<R>(R Function(T) f)` | `SmartResponse<R>` | Transform data, preserve metadata |

---

## SmartException

Unified exception thrown for all network failures.

```dart
class SmartException implements Exception {
  final SmartExceptionType type;
  final String message;
  final int? statusCode;
  final String? requestPath;
  final int? retryAttempts;
  final dynamic rawError;

  bool get isRetryable;   // type is timeout / serverError / noInternet
  bool get isAuthError;   // type is unauthorized / authRefreshFailed
}
```

### Factory constructors

| Constructor | Type set to |
|---|---|
| `SmartException.fromDioException(e)` | Auto-detected from DioException |
| `SmartException.noInternet(path)` | `noInternet` |
| `SmartException.timeout(path)` | `timeout` |
| `SmartException.parseError(path, rawError)` | `parseError` |
| `SmartException.authRefreshFailed(cause)` | `authRefreshFailed` |
| `SmartException.cacheNotFound(path)` | `cacheNotFound` |

---

## SmartExceptionType

```dart
enum SmartExceptionType {
  noInternet,       // SocketException / no connectivity
  timeout,          // connect, send, or receive timeout
  serverError,      // 5xx
  unauthorized,     // 401
  forbidden,        // 403
  notFound,         // 404
  tooManyRequests,  // 429
  cancelled,        // request explicitly cancelled
  parseError,       // JSON deserialisation failure
  authRefreshFailed,// TokenRefresher.refresh() threw
  cacheNotFound,    // cacheOnly strategy + no cache entry
  unknown,          // everything else
}
```

---

## RetryPolicy

```dart
const RetryPolicy({
  int maxAttempts = 3,
  Set<int> retryOnStatusCodes = const {408, 500, 502, 503, 504},
  Set<int> doNotRetryOnStatusCodes = const {},
  bool retryOnConnectionError = true,
  bool retryOnTimeout = true,
  BackoffStrategy backoffStrategy = const ExponentialBackoff(),
})
```

---

## BackoffStrategy

Abstract base; four concrete implementations:

### ConstantBackoff
```dart
const ConstantBackoff({Duration delay = const Duration(seconds: 2)})
```

### LinearBackoff
```dart
const LinearBackoff({
  Duration step = const Duration(seconds: 1),
  Duration maxDelay = const Duration(seconds: 30),
})
// delay(n) = step × (n + 1), clamped to maxDelay
```

### ExponentialBackoff *(recommended)*
```dart
const ExponentialBackoff({
  Duration base = const Duration(seconds: 1),
  Duration maxDelay = const Duration(seconds: 30),
  double jitterFactor = 1.0,   // 0.0 = no jitter, 1.0 = full jitter
})
// delay(n) = base × 2ⁿ × (1 + jitterFactor × random)
```

### DecorrelatedJitterBackoff
```dart
const DecorrelatedJitterBackoff({
  Duration minDelay = const Duration(milliseconds: 500),
  Duration maxDelay = const Duration(seconds: 30),
})
// AWS-style: delay = random(minDelay, previous × 3)
```

---

## CachePolicy

```dart
const CachePolicy({
  bool enabled = true,
  Duration maxAge = const Duration(minutes: 5),
  Duration staleAge = const Duration(minutes: 30),
  CacheStrategy strategy = CacheStrategy.staleWhileRevalidate,
  int maxMemoryEntries = 100,
})
```

---

## CacheStrategy

```dart
enum CacheStrategy {
  cacheFirst,            // cache → network on miss
  networkFirst,          // network → cache fallback on error
  networkOnly,           // always network; writes to cache
  cacheOnly,             // cache only; throws cacheNotFound on miss
  staleWhileRevalidate,  // instant cache + background refresh (default)
}
```

---

## CacheEntry

```dart
class CacheEntry {
  final dynamic data;
  final int statusCode;
  final Map<String, List<String>> headers;
  final DateTime cachedAt;
  final Duration maxAge;
  final Duration? staleAge;

  bool get isExpired;           // cachedAt + maxAge < now
  bool get isWithinStaleAge;    // cachedAt + staleAge >= now
}
```

`CacheEntry.toJson()` / `CacheEntry.fromJson()` are provided for Hive persistence.

---

## CacheKeyBuilder

```dart
abstract class CacheKeyBuilder {
  /// SHA-256 hash of: method + baseUrl + path + sorted(queryParameters).
  /// Query-parameter order is normalised — {b:2, a:1} == {a:1, b:2}.
  static String build(RequestOptions options);
}
```

---

## SmartCache

Abstract interface for custom cache backends.

```dart
abstract class SmartCache {
  Future<void> set(String key, CacheEntry entry);
  Future<CacheEntry?> get(String key);
  Future<void> remove(String key);
  Future<void> clear();
  Future<void> evictExpired();
  Future<int> get entryCount;
}
```

---

## MemoryCache

LRU in-memory cache (L1). Bounded by `maxEntries`.

```dart
MemoryCache({int maxEntries = 100})
```

Implements `SmartCache`. Thread-safe (synchronous operations).

---

## HiveCache

Disk-persistent cache (L2) built on Hive.

```dart
HiveCache({required String boxName})

Future<void> initialize();   // must be called before use
```

Implements `SmartCache`.

---

## TokenPair

```dart
class TokenPair {
  final String accessToken;
  final String refreshToken;
  final int? expiresIn;   // seconds hint from server (optional)

  const TokenPair({
    required String accessToken,
    required String refreshToken,
    int? expiresIn,
  });
}
```

---

## TokenRefresher

Abstract contract. Implement this in your app.

```dart
abstract class TokenRefresher {
  /// Called when the access token has expired.
  /// Must return a fresh [TokenPair].
  /// Throw any exception to signal that re-authentication is required.
  Future<TokenPair> refresh(String refreshToken);
}
```

---

## TokenStorage

Abstract persistence interface.

```dart
abstract class TokenStorage {
  Future<void> saveTokens(TokenPair pair);
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<void> clearTokens();
  Future<bool> hasTokens();   // default: getAccessToken() != null
}
```

---

## InMemoryTokenStorage

Default implementation — RAM only, lost on app kill.

```dart
class InMemoryTokenStorage extends TokenStorage { … }
```

For production use a `SecureStorage`-backed implementation (e.g.
`FlutterSecureStorage`).

---

## TokenManager

Thread-safe JWT manager.

```dart
TokenManager({
  required TokenRefresher refresher,
  TokenStorage? storage,         // default: InMemoryTokenStorage
  SmartLogger? logger,
  int clockOffsetSeconds = 0,    // test hook
})
```

| Method | Description |
|---|---|
| `Future<String?> getValidAccessToken()` | Returns valid token, refreshes if expired. `null` if not authenticated. |
| `Future<void> saveTokens(TokenPair)` | Delegates to `TokenStorage.saveTokens()` |
| `Future<void> clearTokens()` | Delegates to `TokenStorage.clearTokens()` |

Tokens are considered expired **30 seconds** before their `exp` claim to
prevent last-second race conditions.

---

## BatchConfig

```dart
class BatchConfig {
  final String batchEndpoint;              // e.g. '/batch'
  final int maxBatchSize;                  // default: 10
  final Duration windowDuration;           // default: 50 ms
}
```

---

## BatchEntry

Internal model wrapping one request inside a batch.

```dart
class BatchEntry {
  final String path;
  final String method;
  final dynamic data;
  final Map<String, dynamic>? queryParameters;
  Map<String, dynamic> toJson();
}
```

---

## BatchProcessor

Collects `BatchEntry` items during the window, flushes as a single POST,
distributes responses back by index.

```dart
BatchProcessor({required BatchConfig config, required Dio dio})

Future<dynamic> add(BatchEntry entry);   // waits for batch to complete
void dispose();
```

---

## OfflineEntry

Serialisable model for a queued offline request.

```dart
class OfflineEntry {
  final String id;
  final String path;
  final String method;
  final dynamic data;
  final Map<String, dynamic>? queryParameters;
  final Map<String, String>? headers;
  final DateTime enqueuedAt;
  final int maxRetries;
  int retryCount;

  Map<String, dynamic> toJson();
  factory OfflineEntry.fromJson(Map<String, dynamic> json);
}
```

---

## OfflineQueue

Hive-backed persistent FIFO queue.

```dart
OfflineQueue({required HiveCache hiveCache, required String namespace})

Future<void> enqueue(OfflineEntry entry);
Future<List<OfflineEntry>> peekAll();
Future<void> remove(String id);
Future<void> clear();
Future<int> get size;
```

---

## ConnectivityMonitor

Wraps `connectivity_plus`.

```dart
ConnectivityMonitor({
  void Function()? onConnected,
  void Function()? onDisconnected,
})

bool get isOnline;
Future<void> initialize();
void dispose();
```

---

## QueueProcessor

Sequential FIFO replay of `OfflineEntry` items.

```dart
QueueProcessor({
  required OfflineQueue queue,
  required Dio dio,
  void Function(OfflineEntry)? onEntryReplayed,
  void Function(OfflineEntry, Object)? onEntryFailed,
  void Function(OfflineEntry)? onEntryDiscarded,
})

Future<void> process();   // replay all pending entries once
```

---

## RequestDeduplicator

In-flight request registry.

```dart
class RequestDeduplicator {
  /// Returns an existing future if [key] is in-flight; otherwise null.
  Future<Response<dynamic>>? get(String key);

  /// Registers [future] under [key].
  void register(String key, Future<Response<dynamic>> future);

  /// Removes a completed entry.
  void complete(String key);

  /// Removes all entries older than [maxAge].
  void purgeStale({Duration maxAge = const Duration(minutes: 5)});
}
```

---

## SmartLogger

Structured pretty-printer wrapping the `logger` package.

```dart
SmartLogger({bool enabled = true})

void d(String message);   // debug
void i(String message);   // info
void w(String message, {Object? error});   // warning
void e(String message, {Object? error, StackTrace? stackTrace});   // error
```

---

## NetworkUtils

Stateless utility helpers.

```dart
abstract class NetworkUtils {
  static String joinUrl(String base, String path);
  static String encodeQueryParameters(Map<String, dynamic> params);
  static bool isSuccessStatus(int statusCode);     // 200–299
  static bool isClientError(int statusCode);       // 400–499
  static bool isServerError(int statusCode);       // 500–599
  static String formatDuration(Duration d);
}
```

---

*Back to: [Getting Started](getting_started.md) · [Architecture](architecture.md)*
