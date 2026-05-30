import 'dart:async';
import 'package:dio/dio.dart';

import 'batch_config.dart';
import 'batch_entry.dart';
import '../utils/logger.dart';

/// Accumulates individual requests within a time window and dispatches them
/// as a single batched HTTP call to [BatchConfig.batchEndpoint].
///
/// ### Flush triggers
/// A flush occurs when either:
/// 1. The [BatchConfig.windowDuration] timer expires.
/// 2. The [BatchConfig.maxBatchSize] limit is reached.
/// 3. [flush] is called explicitly.
///
/// ### Usage
/// ```dart
/// final user = await batchProcessor.addRequest<User>(
///   path: '/users/1',
///   method: 'GET',
///   fromJson: User.fromJson,
/// );
/// ```
class BatchProcessor {
  final Dio _dio;
  final BatchConfig _config;
  final SmartLogger _logger;

  final List<BatchEntry> _pending = [];
  Timer? _flushTimer;
  bool _disposed = false;

  BatchProcessor({
    required Dio dio,
    required BatchConfig config,
    SmartLogger? logger,
  })  : _dio = dio,
        _config = config,
        _logger = logger ?? SmartLogger();

  // ── Public API ────────────────────────────────────────────────────────────

  /// Adds a request to the batch queue and returns a [Future] that resolves
  /// when the batch containing this request completes.
  Future<T> addRequest<T>({
    required String path,
    required String method,
    dynamic data,
    Map<String, dynamic>? queryParameters,
    T Function(dynamic json)? fromJson,
  }) {
    if (_disposed) {
      return Future.error(
        StateError('BatchProcessor has been disposed.'),
      );
    }

    final completer = Completer<T>();

    final entry = BatchEntry(
      path: path,
      method: method,
      data: data,
      queryParameters: queryParameters,
      completer: Completer<dynamic>()
        ..future.then(
          (raw) => completer.complete(
            fromJson != null ? fromJson(raw) : raw as T,
          ),
          onError: completer.completeError,
        ).ignore(),
        // .ignore() suppresses the orphaned Future<void> returned by .then().
        // Without it, when onError fires, the error propagates into the
        // unlisten .then() return-future and becomes an unhandled async error
        // that the flutter_test runner reports as a test failure.
      fromJson: fromJson,
    );

    _pending.add(entry);

    // Flush immediately when at capacity
    if (_pending.length >= _config.maxBatchSize) {
      _logger.d(
        '📦 Batch at capacity (${_config.maxBatchSize}) — flushing now',
      );
      _flush();
    } else {
      _scheduleFlush();
    }

    return completer.future;
  }

  /// Immediately dispatches all pending requests.
  Future<void> flush() => _flush();

  /// Number of requests currently waiting to be batched.
  int get pendingCount => _pending.length;

  // ── Internals ─────────────────────────────────────────────────────────────

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_config.windowDuration, _flush);
  }

  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;

    if (_pending.isEmpty) return;

    // Snapshot and clear pending list atomically within the event loop
    final batch = List<BatchEntry>.from(_pending);
    _pending.clear();

    _logger.d(
      '📤 Flushing batch of ${batch.length} request(s) '
      'to ${_config.batchEndpoint}',
    );

    try {
      final payload = <String, dynamic>{
        'requests': batch.map((e) => e.toJson()).toList(),
      };

      final response = await _dio.post<dynamic>(
        _config.batchEndpoint,
        data: payload,
        options: Options(headers: _config.headers),
      );

      _resolveAll(batch, response.data);
    } catch (e, st) {
      _logger.e('❌ Batch request failed: $e', error: e, stackTrace: st);
      _rejectAll(batch, e, st);
    }
  }

  void _resolveAll(List<BatchEntry> batch, dynamic responseData) {
    final responseList = _extractResponseList(responseData);

    for (var i = 0; i < batch.length; i++) {
      final entry = batch[i];
      if (entry.isCompleted) continue;

      if (i < responseList.length) {
        final item = responseList[i] as Map<String, dynamic>;
        final status = item['status'] as int? ?? 200;
        final body = item['body'];

        if (status >= 200 && status < 300) {
          entry.completer.complete(body);
          _logger.d('✅ Batch item resolved: ${entry.path} (HTTP $status)');
        } else {
          entry.completer.completeError(
            DioException(
              requestOptions: RequestOptions(path: entry.path),
              message: 'Batch item failed with status $status',
            ),
          );
        }
      } else {
        entry.completer.completeError(
          Exception(
            'Batch response is missing item at index $i for ${entry.path}',
          ),
        );
      }
    }
  }

  void _rejectAll(List<BatchEntry> batch, Object error, StackTrace st) {
    for (final entry in batch) {
      if (!entry.isCompleted) {
        entry.completer.completeError(error, st);
      }
    }
  }

  List<dynamic> _extractResponseList(dynamic data) {
    if (data is Map && data.containsKey('responses')) {
      return data['responses'] as List<dynamic>;
    }
    if (data is List) return data;
    return const [];
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Cancels the pending flush timer and rejects all queued requests.
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    for (final entry in _pending) {
      if (!entry.isCompleted) {
        entry.completer.completeError(
          StateError('BatchProcessor was disposed before request completed.'),
        );
      }
    }
    _pending.clear();
  }
}
