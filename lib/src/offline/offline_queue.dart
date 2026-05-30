import '../cache/hive_cache.dart';
import 'offline_entry.dart';

/// Persistent FIFO queue for storing network requests that could not be
/// sent due to the device being offline.
///
/// Entries are stored in Hive (via [HiveCache]'s raw API) so they survive
/// app restarts. When connectivity is restored, [QueueProcessor] replays
/// them in the order they were enqueued.
///
/// ### Key scheme
/// Each entry uses a composite key:
/// ```
/// <namespace>:<timestamp>_<pathHash>
/// ```
/// This makes keys sortable by enqueue time and unique per request.
class OfflineQueue {
  final HiveCache _hiveCache;
  final String _namespace;

  OfflineQueue({
    required HiveCache hiveCache,
    String namespace = 'smart_network_offline_queue',
  })  : _hiveCache = hiveCache,
        _namespace = namespace;

  // ── CRUD operations ───────────────────────────────────────────────────────

  /// Adds [entry] to the tail of the queue.
  Future<void> enqueue(OfflineEntry entry) async {
    final key =
        '${DateTime.now().millisecondsSinceEpoch}_${entry.path.hashCode.abs()}';
    await _hiveCache.setRaw(_namespace, key, entry.toJsonString());
  }

  /// Returns all queued entries sorted by enqueue time (oldest first).
  Future<List<MapEntry<String, OfflineEntry>>> getAll() async {
    final rawMap = await _hiveCache.getAllRaw(_namespace);

    final parsed = <MapEntry<String, OfflineEntry>>[];
    for (final e in rawMap.entries) {
      try {
        parsed.add(
          MapEntry(e.key, OfflineEntry.fromJsonString(e.value)),
        );
      } catch (_) {
        // Corrupted entry — remove it silently
        await _hiveCache.deleteRaw(_namespace, e.key);
      }
    }

    // Sort by the timestamp prefix of the key
    parsed.sort((a, b) {
      final tsA = int.tryParse(a.key.split('_').first) ?? 0;
      final tsB = int.tryParse(b.key.split('_').first) ?? 0;
      return tsA.compareTo(tsB);
    });

    return parsed;
  }

  /// Removes the entry with [key] from the queue.
  Future<void> dequeue(String key) async {
    await _hiveCache.deleteRaw(_namespace, key);
  }

  /// Updates a modified [entry] (e.g. incremented [OfflineEntry.retryCount]).
  Future<void> update(String key, OfflineEntry entry) async {
    await _hiveCache.setRaw(_namespace, key, entry.toJsonString());
  }

  /// Removes ALL pending entries.
  Future<void> clear() async {
    final all = await getAll();
    for (final e in all) {
      await dequeue(e.key);
    }
  }

  /// Number of entries currently in the queue.
  Future<int> get pendingCount =>
      _hiveCache.countRaw(_namespace);

  @override
  String toString() => 'OfflineQueue(namespace: $_namespace)';
}
