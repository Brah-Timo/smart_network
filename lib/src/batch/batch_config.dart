import 'package:equatable/equatable.dart';

/// Configuration for the request batching system.
///
/// Pass to [SmartConfig.batchConfig] to enable batching.
///
/// ### How batching works
/// Instead of dispatching each request immediately, [BatchProcessor]
/// collects requests for up to [windowDuration] (or until [maxBatchSize]
/// is reached), then sends them all as a single POST to [batchEndpoint].
///
/// ### Server contract
/// The batch endpoint receives:
/// ```json
/// {
///   "requests": [
///     { "method": "GET", "path": "/users/1", "query": {}, "body": null },
///     { "method": "POST", "path": "/posts", "query": {}, "body": {...} }
///   ]
/// }
/// ```
/// And must respond with:
/// ```json
/// {
///   "responses": [
///     { "status": 200, "body": { "id": 1, "name": "Alice" } },
///     { "status": 201, "body": { "id": 42 } }
///   ]
/// }
/// ```
class BatchConfig extends Equatable {
  /// The endpoint path that accepts batched requests.
  final String batchEndpoint;

  /// Maximum number of requests in a single batch. When reached, the
  /// batch is flushed immediately without waiting for [windowDuration].
  /// Default: 10.
  final int maxBatchSize;

  /// How long to wait for additional requests before flushing.
  /// Default: 50 milliseconds.
  final Duration windowDuration;

  /// Default headers merged into the batch POST request.
  final Map<String, dynamic> headers;

  /// Whether to include batch metadata in each request entry.
  final bool includeMetadata;

  const BatchConfig({
    required this.batchEndpoint,
    this.maxBatchSize = 10,
    this.windowDuration = const Duration(milliseconds: 50),
    this.headers = const {},
    this.includeMetadata = false,
  }) : assert(maxBatchSize > 0, 'maxBatchSize must be positive');

  @override
  List<Object?> get props =>
      [batchEndpoint, maxBatchSize, windowDuration, headers, includeMetadata];

  @override
  String toString() => 'BatchConfig('
      'endpoint: $batchEndpoint, '
      'maxSize: $maxBatchSize, '
      'window: ${windowDuration.inMilliseconds}ms)';
}
