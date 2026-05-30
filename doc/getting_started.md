# Getting Started with smart_network

A step-by-step guide from installation to production-ready configuration.

---

## Table of Contents

1. [Installation](#installation)
2. [Initialisation](#initialisation)
3. [Making Your First Request](#making-your-first-request)
4. [Understanding SmartResponse](#understanding-smartresponse)
5. [Error Handling](#error-handling)
6. [Retry Configuration](#retry-configuration)
7. [Cache Configuration](#cache-configuration)
8. [Offline Queue](#offline-queue)
9. [JWT Token Refresh](#jwt-token-refresh)
10. [Request Batching](#request-batching)
11. [Request Deduplication](#request-deduplication)
12. [Diagnostics](#diagnostics)
13. [Frequently Asked Questions](#frequently-asked-questions)

---

## 1. Installation

Add `smart_network` to your `pubspec.yaml`:

```yaml
dependencies:
  smart_network: ^1.0.0
```

Then run:

```bash
flutter pub get
```

---

## 2. Initialisation

Call `initialize()` exactly once, before any requests. The best place is
`main()`, before `runApp()`:

```dart
import 'package:flutter/widgets.dart';
import 'package:smart_network/smart_network.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SmartNetworkClient().initialize(
    SmartConfig(
      baseUrl: 'https://api.example.com',
    ),
  );

  runApp(const MyApp());
}
```

`SmartNetworkClient()` is a **singleton factory** — calling it anywhere in
your app returns the same instance that was initialised in `main()`.

### Full configuration example

```dart
await SmartNetworkClient().initialize(
  SmartConfig(
    baseUrl: 'https://api.example.com',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    enableLogging: true,                    // structured console output

    retryPolicy: RetryPolicy(
      maxAttempts: 3,
      retryOnStatusCodes: {408, 500, 502, 503, 504},
      backoffStrategy: ExponentialBackoff(
        base: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 30),
        jitterFactor: 1.0,
      ),
    ),

    cachePolicy: CachePolicy(
      enabled: true,
      maxAge: const Duration(minutes: 10),
      staleAge: const Duration(minutes: 30),
      strategy: CacheStrategy.staleWhileRevalidate,
    ),

    tokenRefresher: MyTokenRefresher(),     // optional: enable auto token refresh

    batchConfig: BatchConfig(               // optional: enable request batching
      batchEndpoint: '/batch',
      maxBatchSize: 10,
      windowDuration: const Duration(milliseconds: 50),
    ),
  ),
);
```

---

## 3. Making Your First Request

```dart
final client = SmartNetworkClient();

// GET — returns SmartResponse<User>
final res = await client.get<User>(
  '/users/42',
  fromJson: User.fromJson,
);
print(res.data.name);

// POST
await client.post<void>(
  '/messages',
  data: {'text': 'Hello, world!'},
);

// PUT / PATCH / DELETE work the same way
await client.put<User>('/users/42', data: updatedUser.toJson(), fromJson: User.fromJson);
await client.patch<User>('/users/42', data: {'name': 'Alice'}, fromJson: User.fromJson);
await client.delete<void>('/users/42');
```

### Per-request overrides

Every method accepts optional overrides that take precedence over `SmartConfig`:

```dart
await client.get(
  '/live-ticker',
  useCache: false,          // bypass cache for this request
  allowRetry: false,        // no retries for idempotent-sensitive calls
  queueIfOffline: false,    // fail immediately when offline
  headers: {'X-Version': '2'},
  queryParameters: {'lang': 'en'},
  receiveTimeout: const Duration(seconds: 5),
);
```

---

## 4. Understanding SmartResponse

```dart
final res = await client.get<User>('/users/42', fromJson: User.fromJson);

res.data;          // T — the parsed response body
res.statusCode;    // int — e.g. 200
res.headers;       // Map<String, List<String>>
res.fromCache;     // true if served from L1/L2 cache
res.isStale;       // true if a background refresh is in progress (SWR)
res.isQueued;      // true if the request was stored in the offline queue

// Transform the data without losing metadata
final nameRes = res.map((u) => u.name);
```

---

## 5. Error Handling

All failures surface as `SmartException`. You never need to catch `DioException`.

```dart
try {
  final res = await client.get<User>('/users/999');
} on SmartException catch (e) {
  switch (e.type) {
    case SmartExceptionType.noInternet:
      showOfflineBanner();
    case SmartExceptionType.unauthorized:
      navigateToLogin();
    case SmartExceptionType.notFound:
      showNotFoundPage();
    case SmartExceptionType.timeout:
      showRetrySnackbar();
    case SmartExceptionType.serverError:
      reportToSentry(e);
    default:
      debugPrint(e.toString());
  }
}
```

Useful properties:

```dart
e.type;           // SmartExceptionType enum
e.statusCode;     // int? — HTTP status, null for network errors
e.message;        // String — human-readable description
e.requestPath;    // String? — which endpoint failed
e.retryAttempts;  // int? — how many retries were attempted
e.isRetryable;    // bool — safe to retry?
e.isAuthError;    // bool — 401 or authRefreshFailed?
```

---

## 6. Retry Configuration

```dart
RetryPolicy(
  maxAttempts: 3,                           // total attempts including first
  retryOnStatusCodes: {408, 500, 502, 503, 504},
  doNotRetryOnStatusCodes: {400, 401, 403, 422}, // never retry these
  retryOnConnectionError: true,             // SocketException, etc.
  retryOnTimeout: true,
  backoffStrategy: ExponentialBackoff(
    base: const Duration(seconds: 1),       // first retry delay
    maxDelay: const Duration(seconds: 30),  // ceiling
    jitterFactor: 1.0,                      // 0.0 = no jitter, 1.0 = full jitter
  ),
)
```

### Backoff strategy comparison

| Strategy | Formula | Use case |
|---|---|---|
| `ConstantBackoff(delay: 2s)` | Fixed 2 s | Uniform blips, quick recovery expected |
| `LinearBackoff(step: 1s)` | 1 s, 2 s, 3 s, … | Graceful degradation |
| `ExponentialBackoff(base: 1s)` | 1 s, 2 s, 4 s + jitter | **Default — recommended** |
| `DecorrelatedJitterBackoff` | AWS-style spread | High-concurrency, thundering-herd prevention |

Disable retries for a single request:

```dart
await client.post('/payments', data: body, allowRetry: false);
```

---

## 7. Cache Configuration

### Cache strategies

| Strategy | Behaviour |
|---|---|
| `cacheFirst` | Return cache if present; fetch on miss; write to cache |
| `networkFirst` | Fetch network first; fall back to cache on error |
| `networkOnly` | Always fetch; write result to cache; never reads cache |
| `cacheOnly` | Return cache; throw `cacheNotFound` on miss; never fetches |
| `staleWhileRevalidate` | Return cache immediately; refresh in background (**default**) |

```dart
CachePolicy(
  enabled: true,
  maxAge: const Duration(minutes: 10),    // fresh window
  staleAge: const Duration(minutes: 30),  // SWR window
  strategy: CacheStrategy.cacheFirst,
  maxMemoryEntries: 200,                  // L1 LRU limit
)
```

### Cache key

Keys are computed by `CacheKeyBuilder` as a SHA-256 hash of:
`METHOD + baseUrl + path + sorted(queryParameters)`.

Query parameter **order does not matter**: `?b=2&a=1` and `?a=1&b=2`
produce the same key.

### Cache maintenance

```dart
await client.clearCache();             // wipe all L1 + L2 entries
await client.evictExpiredCache();      // remove only expired entries

final info = await client.diagnostics();
print(info['cacheEntries']);           // {'memory': 12, 'hive': 47}
```

---

## 8. Offline Queue

POST / PUT / PATCH / DELETE requests issued while offline are stored to
disk (via Hive) and automatically replayed once connectivity is restored.

```dart
await client.post(
  '/messages',
  data: {'text': 'Hello!'},
  queueIfOffline: true,   // ← opt-in per-request
);
// When offline → SmartResponse(statusCode: 202, isQueued: true)
// Replays automatically on next reconnect
```

Manual queue management:

```dart
final size = await client.offlineQueueSize;     // pending count
await client.processOfflineQueue();             // force immediate replay
await client.clearOfflineQueue();              // discard all pending
```

`QueueProcessor` replays entries sequentially (FIFO). Entries that fail
after `maxRetries` are discarded and `onEntryFailed` is called.

---

## 9. JWT Token Refresh

### Step 1 — Implement `TokenRefresher`

```dart
class MyTokenRefresher extends TokenRefresher {
  @override
  Future<TokenPair> refresh(String refreshToken) async {
    final res = await Dio().post(
      'https://api.example.com/auth/refresh',
      data: {'refresh_token': refreshToken},
    );
    return TokenPair(
      accessToken: res.data['access_token'] as String,
      refreshToken: res.data['refresh_token'] as String,
      expiresIn: res.data['expires_in'] as int?,
    );
  }
}
```

### Step 2 — Pass it to `SmartConfig`

```dart
SmartConfig(
  baseUrl: 'https://api.example.com',
  tokenRefresher: MyTokenRefresher(),
)
```

### Step 3 — Store tokens after login

```dart
final loginRes = await client.post('/auth/login', data: credentials);

await client.setTokens(
  accessToken: loginRes.data['access_token'],
  refreshToken: loginRes.data['refresh_token'],
  expiresIn: loginRes.data['expires_in'],   // optional hint
);
```

### On logout

```dart
await client.clearTokens();
```

### How it works

`TokenManager` uses a **double-checked lock + shared Completer** pattern.
Even if 50 requests expire simultaneously, exactly **one** refresh call is
made to your server. All 50 requests share the result of that single refresh.

Tokens are considered expired **30 seconds early** to avoid last-second
clock-skew races.

### Skip auth for public endpoints

```dart
await client.post(
  '/auth/login',
  data: credentials,
  headers: {'skipAuth': 'true'},
);
```

---

## 10. Request Batching

Combine multiple independent requests into a single HTTP call to your
`/batch` endpoint.

```dart
SmartConfig(
  batchConfig: BatchConfig(
    batchEndpoint: '/batch',
    maxBatchSize: 10,
    windowDuration: const Duration(milliseconds: 50),
  ),
)
```

Use `client.batch()` to enqueue a batched request:

```dart
final [users, posts] = await Future.wait([
  client.batch<User>(
    path: '/users/1', method: 'GET', fromJson: User.fromJson,
  ),
  client.batch<List<Post>>(
    path: '/users/1/posts', method: 'GET',
  ),
]);
```

All requests queued within the `windowDuration` are sent as a single
`POST /batch` with a JSON array body. Your server must respond with a
JSON array in the same order.

---

## 11. Request Deduplication

When two identical GET requests fire before the first returns, only one
HTTP call is made. Both callers receive the same `SmartResponse`.

```dart
// Only ONE HTTP GET /users/1 is made — both futures resolve together
final [a, b] = await Future.wait([
  client.get('/users/1'),
  client.get('/users/1'),
]);
```

Deduplication is keyed on `(method, path, queryParameters)`. It is
enabled by default and only applies to GET requests.

Opt out:

```dart
await client.get('/users/1', headers: {'deduplicate': 'false'});
// or via Dio options:
// Options(extra: {'deduplicate': false})
```

---

## 12. Diagnostics

```dart
final info = await client.diagnostics();
// {
//   'baseUrl': 'https://api.example.com',
//   'isOnline': true,
//   'cacheEntries': {'memory': 12, 'hive': 47},
//   'offlineQueueSize': 0,
//   'batchPending': 0,
// }
```

---

## 13. Frequently Asked Questions

**Q: Can I use `SmartNetworkClient` without Flutter (pure Dart)?**

The package depends on Flutter for Hive Flutter initialisation. For
pure-Dart projects, initialise Hive manually:

```dart
import 'package:hive/hive.dart';
Hive.init('./hive_data');
await SmartNetworkClient().initialize(config);
```

---

**Q: How do I add custom Dio interceptors?**

Pass them via `SmartConfig.extraInterceptors`:

```dart
SmartConfig(
  baseUrl: '...',
  extraInterceptors: [MyLoggingInterceptor(), MyTracingInterceptor()],
)
```

They are appended after all built-in interceptors.

---

**Q: Is it safe to call `initialize()` twice?**

Yes. The second call disposes all resources from the first call (Hive boxes,
subscriptions, etc.) and re-initialises cleanly with the new config.

---

**Q: What happens when `cacheOnly` strategy finds no cache?**

A `SmartException` with type `cacheNotFound` is thrown. Handle it:

```dart
} on SmartException catch (e) {
  if (e.type == SmartExceptionType.cacheNotFound) {
    // No cached data — show empty state
  }
}
```

---

**Q: Does the offline queue survive app restarts?**

Yes. It is stored in a Hive box on disk. Entries are replayed automatically
the next time the device comes online, even after a full app restart.

---

*See also: [API Reference](api_reference.md) · [Architecture](architecture.md)*
