import 'package:equatable/equatable.dart';

/// Controls how SmartNetwork caches GET responses.
///
/// Pass to [SmartConfig.cachePolicy] for global defaults.
///
/// ### Strategy overview
/// | Strategy                  | Cache hit → | Miss → |
/// |---------------------------|-------------|--------|
/// | cacheFirst                | Return cache | Network |
/// | networkFirst              | Network, cache on fail | Network |
/// | networkOnly               | Always network | Network |
/// | cacheOnly                 | Cache or error | Error  |
/// | staleWhileRevalidate      | Return cache + update BG | Network |
///
/// ### Recommended strategy
/// [CacheStrategy.staleWhileRevalidate] gives instant responses while
/// silently keeping the cache fresh — best for most read-heavy UIs.
class CachePolicy extends Equatable {
  /// Master switch for all caching behaviour (default: true).
  final bool enabled;

  /// Time-to-live for a fresh cache entry (default: 5 minutes).
  ///
  /// After this duration the entry is considered expired but may still
  /// be served as stale under [CacheStrategy.staleWhileRevalidate].
  final Duration maxAge;

  /// How long past [maxAge] the entry can still be served as stale
  /// while a background revalidation fetch is in progress.
  ///
  /// Only relevant for [CacheStrategy.staleWhileRevalidate].
  /// Default: 10 minutes.
  final Duration staleAge;

  /// Maximum number of entries kept in the in-memory (L1) cache.
  /// Oldest entries are evicted when the limit is reached. Default: 100.
  final int maxMemoryEntries;

  /// Maximum size in megabytes for the Hive (L2) cache box.
  /// SmartNetwork does not enforce this automatically — it is exposed
  /// so callers can run periodic compaction. Default: 50 MB.
  final int maxHiveSizeMB;

  /// The caching algorithm applied by [CacheInterceptor].
  final CacheStrategy strategy;

  const CachePolicy({
    this.enabled = true,
    this.maxAge = const Duration(minutes: 5),
    this.staleAge = const Duration(minutes: 10),
    this.maxMemoryEntries = 100,
    this.maxHiveSizeMB = 50,
    this.strategy = CacheStrategy.staleWhileRevalidate,
  });

  /// A policy that disables caching entirely.
  static const disabled = CachePolicy(enabled: false);

  /// A policy suitable for near-static data (user profile, config).
  static const longLived = CachePolicy(
    maxAge: Duration(hours: 1),
    staleAge: Duration(hours: 6),
    strategy: CacheStrategy.staleWhileRevalidate,
  );

  /// A policy for rapidly-changing feeds.
  static const shortLived = CachePolicy(
    maxAge: Duration(seconds: 30),
    staleAge: Duration(minutes: 2),
    strategy: CacheStrategy.staleWhileRevalidate,
  );

  CachePolicy copyWith({
    bool? enabled,
    Duration? maxAge,
    Duration? staleAge,
    int? maxMemoryEntries,
    int? maxHiveSizeMB,
    CacheStrategy? strategy,
  }) {
    return CachePolicy(
      enabled: enabled ?? this.enabled,
      maxAge: maxAge ?? this.maxAge,
      staleAge: staleAge ?? this.staleAge,
      maxMemoryEntries: maxMemoryEntries ?? this.maxMemoryEntries,
      maxHiveSizeMB: maxHiveSizeMB ?? this.maxHiveSizeMB,
      strategy: strategy ?? this.strategy,
    );
  }

  @override
  List<Object?> get props =>
      [enabled, maxAge, staleAge, maxMemoryEntries, maxHiveSizeMB, strategy];

  @override
  String toString() => 'CachePolicy('
      'strategy: ${strategy.name}, '
      'maxAge: ${maxAge.inMinutes}m, '
      'staleAge: ${staleAge.inMinutes}m, '
      'enabled: $enabled)';
}

// ── Cache Strategy Enum ───────────────────────────────────────────────────────

/// Determines the logic applied by [CacheInterceptor] for each GET request.
enum CacheStrategy {
  /// Return a valid cached response immediately; only go to network on miss.
  ///
  /// Good for: offline-first apps where stale data is acceptable.
  cacheFirst,

  /// Always try the network first; fall back to cache only on error.
  ///
  /// Good for: data that must be fresh but should work offline.
  networkFirst,

  /// Always fetch from the network; never read from cache.
  /// Still writes the response to cache so [cacheFirst] can use it later.
  ///
  /// Good for: real-time data (stock prices, live sports).
  networkOnly,

  /// Return cached data or throw [SmartExceptionType.cacheNotFound].
  /// Never makes a network request.
  ///
  /// Good for: pre-seeded read-only datasets, truly offline-only flows.
  cacheOnly,

  /// Return stale cache immediately AND fire a background network request
  /// to refresh the cache for the next caller.
  ///
  /// The UI sees instant responses; data converges to fresh on the next read.
  ///
  /// Good for: most feeds, product listings, profiles.
  staleWhileRevalidate,
}
