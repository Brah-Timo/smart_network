import 'dart:collection';

import 'smart_cache.dart';
import 'cache_entry.dart';

/// In-memory LRU cache (L1 layer).
///
/// Uses a [LinkedHashMap] to maintain insertion/access order so that the
/// least-recently-used entry is evicted when [maxEntries] is reached.
///
/// Thread safety: Dart's single-threaded execution model means concurrent
/// access within a single isolate is safe without locks. Across isolates
/// the caller is responsible for coordination.
class MemoryCache extends SmartCache {
  final int maxEntries;

  // LinkedHashMap preserves insertion order; we move accessed keys to end.
  final _store = LinkedHashMap<String, CacheEntry>();

  MemoryCache({this.maxEntries = 100});

  @override
  Future<CacheEntry?> get(String key) async {
    final entry = _store[key];
    if (entry == null) return null;

    // Move to end to mark as recently used (LRU update)
    _store.remove(key);
    _store[key] = entry;
    return entry;
  }

  @override
  Future<void> set(String key, CacheEntry entry) async {
    // Evict LRU entry when at capacity
    if (_store.length >= maxEntries && !_store.containsKey(key)) {
      final lruKey = _store.keys.first;
      _store.remove(lruKey);
    }
    _store[key] = entry;
  }

  @override
  Future<void> remove(String key) async => _store.remove(key);

  @override
  Future<void> clear() async => _store.clear();

  @override
  Future<bool> containsKey(String key) async => _store.containsKey(key);

  @override
  Future<int> get size async => _store.length;

  @override
  Future<int> evictExpired() async {
    final expiredKeys = _store.entries
        .where((e) => e.value.isExpired)
        .map((e) => e.key)
        .toList();

    for (final key in expiredKeys) {
      _store.remove(key);
    }
    return expiredKeys.length;
  }

  /// Returns a snapshot of all currently stored keys (for diagnostics).
  List<String> get keys => List.unmodifiable(_store.keys);

  @override
  String toString() =>
      'MemoryCache(${_store.length}/$maxEntries entries)';
}
