import 'cache_entry.dart';

/// Abstract interface for all cache backends.
///
/// SmartNetwork ships two implementations:
/// - [MemoryCache] — fast, non-persistent L1 cache (in-memory Map)
/// - [HiveCache]   — persistent L2 cache backed by the Hive database
///
/// Custom implementations can be injected by overriding the cache
/// fields in [SmartNetworkClient] before calling `initialize`.
abstract class SmartCache {
  const SmartCache();

  /// Reads the cached entry for [key].
  /// Returns `null` when the key is not present.
  Future<CacheEntry?> get(String key);

  /// Writes [entry] under [key], replacing any existing entry.
  Future<void> set(String key, CacheEntry entry);

  /// Removes the entry for [key]. No-op if not found.
  Future<void> remove(String key);

  /// Removes ALL entries from this cache.
  Future<void> clear();

  /// Returns `true` if [key] exists in this cache.
  Future<bool> containsKey(String key);

  /// Returns the number of entries currently stored.
  Future<int> get size;

  /// Removes all expired entries and returns the number evicted.
  Future<int> evictExpired();
}
