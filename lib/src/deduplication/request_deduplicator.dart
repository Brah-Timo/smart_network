import 'dart:async';
import 'package:dio/dio.dart';
import 'pending_request.dart';

/// Manages a registry of in-flight requests to prevent duplicate HTTP calls.
///
/// ### How it works
/// 1. The first GET request for key K registers a [PendingRequest].
/// 2. Any subsequent identical GET request finds the pending entry and
///    awaits the **same** [Completer.future] — no second HTTP call is made.
/// 3. When Dio resolves/rejects the request, all waiters receive the result.
///
/// ### Concurrency guarantee
/// Dart's event loop is single-threaded, so the Map operations here are
/// inherently atomic within a single isolate — no mutex required.
///
/// ### Stale pending requests
/// Entries are automatically removed once completed. If for any reason a
/// completer is never finished (e.g. Dio bug), [purgeStale] can be called
/// to evict entries older than a threshold.
class RequestDeduplicator {
  final _pending = <String, PendingRequest>{};

  // ── Public API ────────────────────────────────────────────────────────────

  /// Returns the [PendingRequest] for [key], or `null` if none exists.
  PendingRequest? getPending(String key) => _pending[key];

  /// Registers a new [PendingRequest] under [key].
  ///
  /// Caller should check [getPending] first; calling this with an
  /// already-pending key replaces the existing entry.
  void addPending(String key, PendingRequest request) {
    _pending[key] = request;
  }

  /// Resolves all waiters for [key] with [response] and removes the entry.
  void complete(String key, Response<dynamic> response) {
    final pending = _pending.remove(key);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(response);
    }
  }

  /// Rejects all waiters for [key] with [error] and removes the entry.
  void completeError(String key, Object error, [StackTrace? stackTrace]) {
    final pending = _pending.remove(key);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(error, stackTrace);
    }
  }

  /// Returns `true` if [key] has a pending in-flight request.
  bool hasPending(String key) => _pending.containsKey(key);

  /// Number of currently tracked in-flight requests.
  int get pendingCount => _pending.length;

  /// Removes all pending entries older than [maxAge] that have not yet
  /// completed. Their futures will be left dangling — use with care.
  void purgeStale(Duration maxAge) {
    final staleKeys = _pending.entries
        .where((e) => e.value.age > maxAge)
        .map((e) => e.key)
        .toList();

    for (final key in staleKeys) {
      final p = _pending.remove(key);
      if (p != null && !p.isCompleted) {
        p.completer.completeError(
          TimeoutException(
            'Deduplication entry expired after ${maxAge.inSeconds}s',
          ),
        );
      }
    }
  }

  /// Clears all pending entries, rejecting each future.
  void dispose() {
    final keys = List<String>.from(_pending.keys);
    for (final key in keys) {
      completeError(
        key,
        StateError('RequestDeduplicator disposed'),
      );
    }
    _pending.clear();
  }
}
