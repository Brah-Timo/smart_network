# Changelog

All notable changes to `smart_network` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-05-29

### Added

#### Core
- `SmartNetworkClient` — singleton entry point, fully type-safe HTTP API
  (`get`, `post`, `put`, `patch`, `delete`, `batch`)
- `SmartConfig` — central, immutable configuration object with `copyWith`
- `SmartRequest` — request model with `uniqueKey`, `resolvedExtra`, and
  per-request overrides for cache, retry, and offline flags
- `SmartResponse<T>` — typed response wrapper with `fromCache`, `isStale`,
  `isQueued`, `map<R>`, and header helpers
- `SmartException` — unified exception with `SmartExceptionType` enum,
  factory constructors for every error category, `isRetryable`, `isAuthError`

#### Retry
- `RetryPolicy` — configurable `maxAttempts`, `retryOnStatusCodes`,
  `doNotRetryOnStatusCodes`, connection and timeout retry flags
- `RetryEvaluator` — pure, independently testable retry decision logic
- `BackoffStrategy` (abstract) with four implementations:
  - `ConstantBackoff` — fixed delay
  - `LinearBackoff` — linearly growing delay with `maxDelay` cap
  - `ExponentialBackoff` — `base × 2ⁿ + jitter` with configurable
    `jitterFactor` (0–100%) and `maxDelay` cap (default; **recommended**)
  - `DecorrelatedJitterBackoff` — AWS-style decorrelated jitter
- `RetryInterceptor` — Dio interceptor that coordinates with `RetryEvaluator`

#### Cache
- Two-layer architecture: `MemoryCache` (L1, LRU) + `HiveCache` (L2, disk)
- `SmartCache` — abstract interface for custom backends
- `CacheEntry` — entry model with `isExpired`, `isWithinStaleAge`, full
  JSON serialisation
- `CachePolicy` — configurable TTL, stale window, max entries, and strategy
- `CacheStrategy` enum: `cacheFirst`, `networkFirst`, `networkOnly`,
  `cacheOnly`, `staleWhileRevalidate`
- `CacheKeyBuilder` — SHA-256 hashed, order-independent, header-aware key
- `CacheInterceptor` — implements all 5 strategies with background
  revalidation and two-layer promotion

#### Deduplication
- `RequestDeduplicator` — in-flight request registry with `purgeStale`
- `PendingRequest` — `Completer`-backed waiter with age tracking
- `DedupInterceptor` — collapses identical concurrent GETs into one HTTP call

#### Offline
- `OfflineEntry` — fully serialisable queue item with `maxRetries` support
- `OfflineQueue` — persistent FIFO queue built on Hive with sorted replay
- `ConnectivityMonitor` — wraps `connectivity_plus` with
  `onConnected`/`onDisconnected` callbacks
- `QueueProcessor` — sequential FIFO replay with per-entry error handling
  and `onEntryReplayed`/`onEntryFailed`/`onEntryDiscarded` callbacks
- `OfflineInterceptor` — queues or rejects requests based on connectivity
  and per-request `queueIfOffline` flag

#### Auth
- `TokenPair` — value object holding access + refresh tokens
- `TokenRefresher` (abstract) — pluggable contract for host app auth logic
- `TokenStorage` (abstract) + `InMemoryTokenStorage` — pluggable persistence
- `TokenManager` — thread-safe JWT manager using `synchronized` Lock +
  `Completer` to prevent refresh race conditions; 30-second expiry buffer
- `AuthInterceptor` — injects `Authorization` header, handles 401 by
  force-refreshing and retrying once

#### Batch
- `BatchConfig` — configurable endpoint, window duration, max size
- `BatchEntry` — per-request entry with `toJson()` and `Completer`
- `BatchProcessor` — collects requests in a window, flushes as a single POST,
  distributes responses back to individual futures
- `BatchInterceptor` — routes requests tagged with `extra['batch'] = true`

#### Utils
- `SmartLogger` — structured pretty-printer wrapping the `logger` package
- `NetworkUtils` — stateless helpers: URL joining, query encoding,
  status code checks, duration formatting

#### Diagnostics
- `SmartNetworkClient.diagnostics()` — live snapshot of cache sizes,
  queue length, connectivity, and batch pending count
- `SmartNetworkClient.evictExpiredCache()` — manual eviction
- `SmartNetworkClient.clearCache()` / `clearOfflineQueue()` — maintenance

---

[1.0.0]: https://github.com/your-username/smart_network/releases/tag/v1.0.0
