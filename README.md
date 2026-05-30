# smart_network 🚀

[![pub.dev](https://img.shields.io/badge/pub.dev-1.0.0-blue)](https://pub.dev/packages/smart_network)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-%E2%89%A53.10-blue)](https://flutter.dev)

**A smart, production-ready networking layer for Flutter.**

Built on top of [Dio](https://pub.dev/packages/dio), `smart_network` gives
you a robust HTTP client with **zero boilerplate** for the features every
production app needs:

| Feature | Description |
|---|---|
| 🔁 **Retry** | Exponential / Linear / Constant / Decorrelated-Jitter backoff |
| 🗄️ **Cache** | 5 strategies · Two-layer Memory + Hive · Stale-While-Revalidate |
| 🔀 **Deduplication** | Collapses identical concurrent GETs into one HTTP call |
| 📵 **Offline Queue** | Disk-persistent queue · Auto-replays on reconnect |
| 🔐 **Auto Token Refresh** | Thread-safe JWT refresh · Race-condition proof |
| 📦 **Request Batching** | Groups multiple requests into a single HTTP call |
| 🪵 **Logging** | Structured pretty-print via `logger` package |
| 🔬 **Diagnostics** | Live cache/queue snapshots + manual maintenance API |

---

## Installation

```yaml
dependencies:
  smart_network: ^1.0.0
```

---

## Quick Start

```dart
import 'package:smart_network/smart_network.dart';

// ── 1. Initialise once in main() ──────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SmartNetworkClient().initialize(
    SmartConfig(
      baseUrl: 'https://api.example.com',
      retryPolicy: RetryPolicy(maxAttempts: 3),
      cachePolicy: CachePolicy(
        maxAge: Duration(minutes: 10),
        strategy: CacheStrategy.staleWhileRevalidate,
      ),
      tokenRefresher: MyTokenRefresher(), // optional
    ),
  );

  runApp(const MyApp());
}

// ── 2. Use anywhere ───────────────────────────────────────────────────────────
final client = SmartNetworkClient();

final res = await client.get<User>(
  '/users/42',
  fromJson: User.fromJson,
);

print(res.data.name);       // User object
print(res.fromCache);       // true if served from cache
print(res.isStale);         // true if background revalidation is pending
```

---

## Features In Depth

### 🔁 Retry

```dart
RetryPolicy(
  maxAttempts: 3,
  retryOnStatusCodes: {408, 500, 502, 503, 504},
  backoffStrategy: ExponentialBackoff(
    base: Duration(seconds: 1),
    maxDelay: Duration(seconds: 30),
    jitterFactor: 1.0,   // full jitter — prevents thundering herd
  ),
)
```

Four built-in back-off strategies:

| Strategy | Formula | Use case |
|---|---|---|
| `ConstantBackoff` | `delay` | Brief uniform blips |
| `LinearBackoff` | `step × (n+1)` | Graceful degradation |
| `ExponentialBackoff` | `base × 2ⁿ + jitter` | **Default — recommended** |
| `DecorrelatedJitterBackoff` | AWS-style spread | High-concurrency clients |

Disable retries per-request:
```dart
await client.post('/pay', data: body, allowRetry: false);
```

---

### 🗄️ Cache

```dart
CachePolicy(
  enabled: true,
  maxAge: Duration(minutes: 10),   // fresh window
  staleAge: Duration(minutes: 30), // stale-while-revalidate window
  strategy: CacheStrategy.staleWhileRevalidate,
)
```

| Strategy | Description |
|---|---|
| `cacheFirst` | Cache → Network on miss |
| `networkFirst` | Network → Cache fallback on error |
| `networkOnly` | Always network; writes to cache |
| `cacheOnly` | Cache only; throws on miss |
| `staleWhileRevalidate` | Instant cache + background refresh (**default**) |

Cache is **two-layer**:
- **L1** — `MemoryCache` (LRU, sub-millisecond)
- **L2** — `HiveCache` (disk, survives app restarts)

Disable cache per-request:
```dart
await client.get('/live-price', useCache: false);
```

---

### 🔀 Request Deduplication

When the same GET fires twice before the first returns, SmartNetwork
makes **one** HTTP call and delivers the result to both callers:

```dart
// Both receive the exact same response — only 1 HTTP call
final [res1, res2] = await Future.wait([
  client.get('/users/1'),
  client.get('/users/1'),
]);
```

Disable per-request:
```dart
await client.get('/users/1', headers: {'deduplicate': 'false'});
// or via extra:
// Options(extra: {'deduplicate': false})
```

---

### 📵 Offline Queue

POST/PUT/DELETE requests are persisted to disk when the device is offline
and replayed automatically on reconnect:

```dart
// Survives app restarts — stored in Hive
await client.post(
  '/messages',
  data: {'text': 'Hello!'},
  queueIfOffline: true,
);

// Response when offline:
// SmartResponse(statusCode: 202, isQueued: true)
```

Manual control:
```dart
final pending = await client.offlineQueueSize;   // count
await client.processOfflineQueue();              // force replay
await client.clearOfflineQueue();               // discard all
```

---

### 🔐 Auto Token Refresh

Implement `TokenRefresher` with your auth logic:

```dart
class MyTokenRefresher extends TokenRefresher {
  @override
  Future<TokenPair> refresh(String refreshToken) async {
    final res = await dio.post('/auth/refresh',
        data: {'refresh_token': refreshToken});
    return TokenPair(
      accessToken: res.data['access_token'],
      refreshToken: res.data['refresh_token'],
    );
  }
}
```

Then pass it to `SmartConfig`:
```dart
SmartConfig(
  baseUrl: '...',
  tokenRefresher: MyTokenRefresher(),
)
```

After login, store tokens:
```dart
await client.setTokens(
  accessToken: loginResponse.accessToken,
  refreshToken: loginResponse.refreshToken,
);
```

On logout:
```dart
await client.clearTokens();
```

Token storage is **thread-safe** — even if 10 requests expire simultaneously,
only **one** refresh call is made; all 10 requests receive the new token.

Opt out of auth per-request (for login/register endpoints):
```dart
await client.post(
  '/auth/login',
  data: credentials,
  headers: {'skipAuth': 'true'},
);
// or: Options(extra: {'skipAuth': true})
```

---

### 📦 Request Batching

```dart
SmartConfig(
  batchConfig: BatchConfig(
    batchEndpoint: '/batch',
    maxBatchSize: 10,
    windowDuration: Duration(milliseconds: 50),
  ),
)
```

Use the `batch` method for individual requests:
```dart
final [users, posts] = await Future.wait([
  client.batch<User>(path: '/users/1', method: 'GET', fromJson: User.fromJson),
  client.batch<List>(path: '/users/1/posts', method: 'GET'),
]);
```

Or tag any request with `extra['batch'] = true` to route through
`BatchInterceptor` automatically.

---

### 🔬 Diagnostics

```dart
final info = await client.diagnostics();
// {
//   'baseUrl': 'https://api.example.com',
//   'isOnline': true,
//   'cacheEntries': { 'memory': 12, 'hive': 47 },
//   'offlineQueueSize': 0,
//   'batchPending': 0,
// }
```

Cache maintenance:
```dart
await client.clearCache();              // wipe everything
await client.evictExpiredCache();       // remove only expired entries
```

---

## Error Handling

All errors are wrapped in `SmartException`:

```dart
try {
  final res = await client.get('/users/1');
} on SmartException catch (e) {
  switch (e.type) {
    case SmartExceptionType.noInternet:
      showOfflineBanner();
    case SmartExceptionType.unauthorized:
      navigateToLogin();
    case SmartExceptionType.timeout:
      showRetrySnackbar();
    case SmartExceptionType.serverError:
      showGenericError(e.message);
    default:
      debugPrint(e.toString());
  }
}
```

`SmartExceptionType` values:

| Type | Trigger |
|---|---|
| `noInternet` | No connectivity / SocketException |
| `timeout` | Connect / send / receive timeout |
| `serverError` | 5xx responses |
| `unauthorized` | 401 |
| `forbidden` | 403 |
| `notFound` | 404 |
| `tooManyRequests` | 429 |
| `cancelled` | Request cancelled |
| `parseError` | JSON deserialisation failure |
| `authRefreshFailed` | Token refresh failed |
| `cacheNotFound` | `cacheOnly` strategy + no cache |
| `unknown` | Everything else |

---

## Architecture

```
SmartNetworkClient (singleton)
        │
        ▼
   ┌─────────────────────────────────────────────────┐
   │           Interceptor Chain (onRequest)          │
   │                                                  │
   │  1. LogInterceptor    ← records everything       │
   │  2. AuthInterceptor   ← Bearer token + 401 retry │
   │  3. CacheInterceptor  ← 5-strategy L1/L2 cache   │
   │  4. DedupInterceptor  ← collapses duplicate GETs │
   │  5. BatchInterceptor  ← routes to BatchProcessor │
   │  6. OfflineInterceptor← queues/rejects offline   │
   │  7. RetryInterceptor  ← backoff retry on errors  │
   │  8. Custom extras     ← user-supplied             │
   └─────────────────────────────────────────────────┘
        │
        ▼
   Dio HTTP client → API Server
        │
        ▼
   SmartResponse<T>
   ├── data: T
   ├── statusCode: int
   ├── fromCache: bool
   ├── isStale: bool
   └── isQueued: bool
```

Design patterns used:
- **Singleton** — one client per app
- **Interceptor Chain** — like OkHttp / Express middleware
- **Strategy Pattern** — pluggable `BackoffStrategy`, `CacheStrategy`, `TokenStorage`
- **Repository Pattern** — `MemoryCache` + `HiveCache` behind `SmartCache` interface
- **Completer Pattern** — race-condition-safe token refresh
- **Decorator Pattern** — `SmartResponse<T>` wraps Dio's raw response

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `dio` | ^5.4.0 | HTTP client |
| `hive` | ^2.2.3 | Persistent cache & offline queue |
| `hive_flutter` | ^1.1.0 | Hive Flutter integration |
| `connectivity_plus` | ^6.0.0 | Network state monitoring |
| `crypto` | ^3.0.3 | SHA-256 cache key hashing |
| `equatable` | ^2.0.5 | Value equality |
| `synchronized` | ^3.1.0 | Mutex for token refresh |
| `logger` | ^2.0.2+1 | Structured logging |

---

## Comparison

| Feature | `smart_network` | `dio` | `http` | `retrofit` |
|---|:---:|:---:|:---:|:---:|
| Auto Retry | ✅ 4 strategies | ❌ | ❌ | ❌ |
| Cache | ✅ 5 strategies | ❌ | ❌ | ❌ |
| Deduplication | ✅ | ❌ | ❌ | ❌ |
| Offline Queue | ✅ persistent | ❌ | ❌ | ❌ |
| Token Refresh | ✅ race-safe | ❌ | ❌ | ❌ |
| Batching | ✅ | ❌ | ❌ | ❌ |
| Type-safe Response | ✅ | partial | ❌ | ✅ |
| Built-in Logging | ✅ | ✅ | ❌ | ❌ |

---

## License

MIT — see [LICENSE](LICENSE).
