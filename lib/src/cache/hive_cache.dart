import 'package:hive_flutter/hive_flutter.dart';

import 'smart_cache.dart';
import 'cache_entry.dart';

/// Persistent cache backed by [Hive] — the L2 (disk) cache layer.
///
/// Data survives app restarts, making this the source of truth for
/// offline scenarios and stale-while-revalidate strategies.
///
/// ### Initialisation
/// Call [initialize] once during app startup (before the client is used):
/// ```dart
/// final hiveCache = HiveCache(boxName: 'smart_network_cache');
/// await hiveCache.initialize();
/// ```
///
/// ### Storage format
/// Each entry is stored as a JSON-encoded string keyed by the
/// [CacheEntry]'s cache key. Strings are universally supported by Hive
/// without requiring generated adapters.
class HiveCache extends SmartCache {
  final String _boxName;
  late Box<String> _box;
  bool _initialised = false;

  HiveCache({String boxName = 'smart_network_cache'}) : _boxName = boxName;

  /// Opens the Hive box. Must be called (and awaited) before any other method.
  Future<void> initialize() async {
    if (_initialised) return;
    await Hive.initFlutter();
    _box = await Hive.openBox<String>(_boxName);
    _initialised = true;
  }

  void _assertInitialised() {
    if (!_initialised) {
      throw StateError(
        'HiveCache is not initialised. '
        'Call await hiveCache.initialize() before using it.',
      );
    }
  }

  @override
  Future<CacheEntry?> get(String key) async {
    _assertInitialised();
    final raw = _box.get(key);
    if (raw == null) return null;

    try {
      return CacheEntry.fromJsonString(raw);
    } catch (_) {
      // Corrupted entry — remove it silently
      await _box.delete(key);
      return null;
    }
  }

  @override
  Future<void> set(String key, CacheEntry entry) async {
    _assertInitialised();
    await _box.put(key, entry.toJsonString());
  }

  @override
  Future<void> remove(String key) async {
    _assertInitialised();
    await _box.delete(key);
  }

  @override
  Future<void> clear() async {
    _assertInitialised();
    await _box.clear();
  }

  @override
  Future<bool> containsKey(String key) async {
    _assertInitialised();
    return _box.containsKey(key);
  }

  @override
  Future<int> get size async {
    _assertInitialised();
    return _box.length;
  }

  @override
  Future<int> evictExpired() async {
    _assertInitialised();
    final expiredKeys = <String>[];

    for (final key in _box.keys.cast<String>()) {
      final raw = _box.get(key);
      if (raw == null) continue;
      try {
        final entry = CacheEntry.fromJsonString(raw);
        if (entry.isExpired) expiredKeys.add(key);
      } catch (_) {
        // Corrupted entry
        expiredKeys.add(key);
      }
    }

    await _box.deleteAll(expiredKeys);
    return expiredKeys.length;
  }

  // ── Raw key/value helpers for OfflineQueue ───────────────────────────────

  /// Stores a raw string under [namespace]:[key].
  Future<void> setRaw(String namespace, String key, String value) async {
    _assertInitialised();
    await _box.put('$namespace:$key', value);
  }

  /// Reads a raw string stored under [namespace]:[key].
  Future<String?> getRaw(String namespace, String key) async {
    _assertInitialised();
    return _box.get('$namespace:$key');
  }

  /// Deletes a raw entry stored under [namespace]:[key].
  Future<void> deleteRaw(String namespace, String key) async {
    _assertInitialised();
    await _box.delete('$namespace:$key');
  }

  /// Returns all entries whose Hive key starts with [namespace].
  Future<Map<String, String>> getAllRaw(String namespace) async {
    _assertInitialised();
    final prefix = '$namespace:';
    final result = <String, String>{};

    for (final rawKey in _box.keys.cast<String>()) {
      if (rawKey.startsWith(prefix)) {
        final val = _box.get(rawKey);
        if (val != null) result[rawKey.substring(prefix.length)] = val;
      }
    }
    return result;
  }

  /// Returns the count of raw entries under [namespace].
  Future<int> countRaw(String namespace) async {
    final prefix = '$namespace:';
    return _box.keys.cast<String>().where((k) => k.startsWith(prefix)).length;
  }

  /// Triggers Hive's internal compaction to reclaim deleted-record space.
  Future<void> compact() async {
    _assertInitialised();
    await _box.compact();
  }

  /// Closes the Hive box. Call during app shutdown.
  Future<void> close() async {
    if (_initialised) {
      await _box.close();
      _initialised = false;
    }
  }

  @override
  String toString() => 'HiveCache(box: $_boxName, '
      'entries: ${_initialised ? _box.length : "not initialised"})';
}
