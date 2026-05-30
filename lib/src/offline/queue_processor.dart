import 'package:dio/dio.dart';

import 'offline_queue.dart';
import 'offline_entry.dart';
import '../utils/logger.dart';

/// Replays all entries in [OfflineQueue] against the network when
/// connectivity is restored.
///
/// ### Processing guarantee
/// - Entries are processed in FIFO order (oldest first).
/// - On success: the entry is permanently removed from the queue.
/// - On failure: [retryCount] is incremented; if [maxRetries] is
///   exceeded, the entry is discarded and [onEntryDiscarded] is called.
/// - A concurrent call to [processQueue] while one is already running
///   is a no-op (protected by [_isProcessing]).
class QueueProcessor {
  final OfflineQueue _queue;
  final Dio _dio;
  final String _baseUrl;
  final SmartLogger _logger;

  bool _isProcessing = false;

  QueueProcessor({
    required OfflineQueue queue,
    required Dio dio,
    required String baseUrl,
    SmartLogger? logger,
  })  : _queue = queue,
        _dio = dio,
        _baseUrl = baseUrl,
        _logger = logger ?? SmartLogger();

  // ── Callbacks ─────────────────────────────────────────────────────────────

  /// Invoked when an entry is successfully replayed.
  void Function(OfflineEntry entry)? onEntryReplayed;

  /// Invoked when an entry fails and is retried.
  void Function(OfflineEntry entry, Object error)? onEntryFailed;

  /// Invoked when an entry exceeds [OfflineEntry.maxRetries] and is removed.
  void Function(OfflineEntry entry)? onEntryDiscarded;

  // ── Main entry point ──────────────────────────────────────────────────────

  /// Processes the offline queue sequentially.
  ///
  /// Safe to call from [ConnectivityMonitor.onConnected].
  Future<void> processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    final count = await _queue.pendingCount;
    if (count == 0) {
      _isProcessing = false;
      return;
    }

    _logger.i('📡 Processing offline queue — $count pending entries');

    try {
      final entries = await _queue.getAll();

      for (final MapEntry(key: entryKey, value: entry) in entries) {
        await _processEntry(entryKey, entry);
      }

      final remaining = await _queue.pendingCount;
      _logger.i('✅ Offline queue processed — $remaining entries remaining');
    } finally {
      _isProcessing = false;
    }
  }

  // ── Private Helpers ───────────────────────────────────────────────────────

  Future<void> _processEntry(String key, OfflineEntry entry) async {
    // Skip entries that have exceeded their retry budget
    if (entry.hasExceededMaxRetries) {
      _logger.w('🗑️ Discarding entry (max retries exceeded): ${entry.path}');
      await _queue.dequeue(key);
      onEntryDiscarded?.call(entry);
      return;
    }

    try {
      _logger.d(
        '📤 Replaying queued request: '
        '${entry.method} ${entry.path} '
        '(attempt ${entry.retryCount + 1})',
      );

      await _dio.fetch<dynamic>(
        entry.toRequestOptions(_baseUrl),
      );

      _logger.i('✅ Queued request succeeded: ${entry.method} ${entry.path}');
      await _queue.dequeue(key);
      onEntryReplayed?.call(entry);
    } catch (e) {
      entry.retryCount++;
      _logger.w(
        '⚠️ Queued request failed: ${entry.method} ${entry.path} '
        '— retries: ${entry.retryCount}/${entry.maxRetries ?? "∞"} '
        '— error: $e',
      );

      if (entry.hasExceededMaxRetries) {
        await _queue.dequeue(key);
        onEntryDiscarded?.call(entry);
      } else {
        await _queue.update(key, entry);
        onEntryFailed?.call(entry, e);
      }
    }
  }

  bool get isProcessing => _isProcessing;
}
