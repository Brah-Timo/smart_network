# smart_network — Architecture

Internal design, data flow, and design patterns.

---

## Overview

```
Your App
    │
    ▼
SmartNetworkClient (Singleton)
    │
    ├── SmartConfig  ─────────── immutable, injected at initialize()
    │
    ▼
┌──────────────────────────────────────────────────────────────────┐
│                    Dio Interceptor Chain                          │
│                                                                  │
│  1. LogInterceptor       ← structured request/response log       │
│  2. AuthInterceptor      ← inject Bearer, handle 401 refresh     │
│  3. CacheInterceptor     ← 5-strategy L1/L2 cache                │
│  4. DedupInterceptor     ← collapse identical in-flight GETs     │
│  5. BatchInterceptor     ← route batch-tagged requests           │
│  6. OfflineInterceptor   ← queue/reject when offline             │
│  7. RetryInterceptor     ← exponential/linear/constant backoff   │
│  8. extraInterceptors    ← user-supplied (appended last)         │
└──────────────────────────────────────────────────────────────────┘
    │
    ▼
Dio HTTP Client  ──────────────────────────────── API Server
    │
    ▼
SmartResponse<T>
├── data: T
├── statusCode: int
├── fromCache: bool
├── isStale: bool
└── isQueued: bool
```

---

## Interceptor Execution Order

Dio interceptors run in **registration order** for `onRequest` and in
**reverse registration order** for `onResponse`/`onError`. This matters for
the Auth ↔ Retry interaction:

```
onRequest:  Log → Auth → Cache → Dedup → Batch → Offline → Retry → extras
onResponse: extras → Retry → Offline → Batch → Dedup → Cache → Auth → Log
onError:    extras → Retry (retries here) → Offline → … → Log
```

`RetryInterceptor` re-fires the request from `onError`, which re-enters the
chain from the top — allowing `AuthInterceptor` to inject a freshly refreshed
token on the retry.

---

## Cache Architecture

```
Request
  │
  ▼
CacheInterceptor
  │
  ├─ strategy = cacheFirst?       → read L1 → read L2 → network on miss → write L1+L2
  ├─ strategy = networkFirst?     → network → write L1+L2 → L2 fallback on error
  ├─ strategy = networkOnly?      → network always → write L1+L2
  ├─ strategy = cacheOnly?        → L1 → L2 → throw cacheNotFound on miss
  └─ strategy = staleWhileRevalidate (default)?
       → L1 or L2 (return immediately, even if stale)
       → if stale: fire background network request → write L1+L2 silently
       → SmartResponse.isStale = true when background revalidation pending
```

### Two-layer promotion

On a network fetch, the result is written to both L1 (MemoryCache) and L2
(HiveCache). On an L2 hit, the entry is also promoted to L1 for the next
request.

### Cache key uniqueness

`CacheKeyBuilder.build()` computes:

```
SHA-256( UPPERCASE(method) + baseUrl + path + sorted(queryParameters) )
```

Query parameters are sorted lexicographically so `?b=2&a=1` and `?a=1&b=2`
produce the same key. The hash is hex-encoded for Hive storage.

---

## Token Refresh — Race-Safe Pattern

```
Thread A → token expired → acquire _lock → start refresh → create Completer
Thread B → token expired → _lock held   → await Completer
Thread C → token expired → _lock held   → await Completer

Thread A finishes → complete(newPair) → B and C both receive newPair
Thread A sets _activeRefreshCompleter = null
```

Exactly **one** `TokenRefresher.refresh()` call is made per expiry cycle,
regardless of the number of concurrent requests.

Tokens are marked expired **30 seconds early** (grace window) to avoid
last-second clock-skew races between the client and the auth server.

---

## Offline Queue — Persistence and Replay

```
Request (POST/PUT/PATCH/DELETE)
    │
    ▼
OfflineInterceptor
    │
    ├─ online?  ── pass through to network
    │
    └─ offline + queueIfOffline=true?
           │
           ▼
       OfflineEntry.toJson() ──► HiveBox (disk-persistent, survives restart)
       Return SmartResponse(statusCode: 202, isQueued: true)

ConnectivityMonitor detects reconnect
    │
    ▼
QueueProcessor.process()
    │
    ├─ read all OfflineEntry sorted by enqueuedAt (FIFO)
    └─ for each entry: Dio.request() → onEntryReplayed / onEntryFailed
         - if retryCount >= maxRetries → onEntryDiscarded → remove
```

---

## Request Deduplication

```
GET /users/1  (first request, key K)
    │
    ▼
DedupInterceptor.onRequest
    │
    ├─ K not in-flight? → register(K, future) → proceed to network
    │
    └─ K in-flight?     → return existing future (no new HTTP call)

Network returns
    │
    ▼
DedupInterceptor.onResponse → complete(K) → both callers receive response
```

Only GET requests are deduplicated. The key is `uniqueKey` from `SmartRequest`
(method + path + sorted query params — same algorithm as `CacheKeyBuilder`).

---

## Batch Processing

```
client.batch('/users/1')  ─┐
client.batch('/users/2')  ─┤── window (e.g. 50ms) ──► BatchProcessor
client.batch('/users/3')  ─┘
                                    │
                                    ▼
                          POST /batch
                          Body: [ {path:'/users/1',method:'GET'},
                                  {path:'/users/2',method:'GET'},
                                  {path:'/users/3',method:'GET'} ]
                                    │
                          Server responds:
                          [ userResponse1, userResponse2, userResponse3 ]
                                    │
                          BatchProcessor distributes by index
                          ── Completer 1 completes(userResponse1)
                          ── Completer 2 completes(userResponse2)
                          ── Completer 3 completes(userResponse3)
```

---

## Design Patterns

| Pattern | Where used |
|---|---|
| **Singleton** | `SmartNetworkClient` — one instance per app via factory constructor |
| **Interceptor Chain** | Dio interceptors — like OkHttp / Express middleware |
| **Strategy** | `BackoffStrategy`, `CacheStrategy`, `TokenStorage` — pluggable algorithms |
| **Repository** | `MemoryCache` + `HiveCache` behind `SmartCache` abstract interface |
| **Completer / Double-checked Lock** | `TokenManager` — race-safe token refresh |
| **Decorator** | `SmartResponse<T>` — wraps Dio's raw `Response<dynamic>` with metadata |
| **Command + Queue** | `OfflineEntry` in `OfflineQueue` — serialisable requests for later replay |
| **Observer** | `ConnectivityMonitor` — `onConnected` / `onDisconnected` callbacks |

---

## Directory Structure

```
lib/
├── smart_network.dart          ← barrel export
└── src/
    ├── auth/
    │   ├── token_manager.dart      ← thread-safe JWT refresh
    │   ├── token_refresher.dart    ← abstract contract + TokenPair
    │   └── token_storage.dart      ← abstract + InMemoryTokenStorage
    ├── batch/
    │   ├── batch_config.dart
    │   ├── batch_entry.dart
    │   └── batch_processor.dart
    ├── cache/
    │   ├── cache_entry.dart
    │   ├── cache_key_builder.dart
    │   ├── cache_policy.dart
    │   ├── hive_cache.dart
    │   ├── memory_cache.dart
    │   └── smart_cache.dart        ← abstract interface
    ├── core/
    │   ├── smart_config.dart
    │   ├── smart_exception.dart
    │   ├── smart_network_client.dart  ← singleton, HTTP methods
    │   ├── smart_request.dart
    │   └── smart_response.dart
    ├── deduplication/
    │   ├── pending_request.dart
    │   └── request_deduplicator.dart
    ├── interceptors/
    │   ├── auth_interceptor.dart
    │   ├── batch_interceptor.dart
    │   ├── cache_interceptor.dart
    │   ├── dedup_interceptor.dart
    │   ├── offline_interceptor.dart
    │   └── retry_interceptor.dart
    ├── offline/
    │   ├── connectivity_monitor.dart
    │   ├── offline_entry.dart
    │   ├── offline_queue.dart
    │   └── queue_processor.dart
    ├── retry/
    │   ├── backoff_strategy.dart
    │   ├── retry_evaluator.dart
    │   └── retry_policy.dart
    └── utils/
        ├── logger.dart
        └── network_utils.dart
```

---

*Back to: [Getting Started](getting_started.md) · [API Reference](api_reference.md)*
