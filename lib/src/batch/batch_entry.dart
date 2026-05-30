import 'dart:async';

/// Represents a single request pending inside [BatchProcessor].
///
/// Holds the serialisable request data alongside a [Completer] that
/// resolves when the batch response arrives and is parsed.
class BatchEntry {
  /// HTTP method for this request.
  final String method;

  /// Path relative to the base URL.
  final String path;

  /// Request body (must be JSON-serialisable).
  final dynamic data;

  /// Query parameters.
  final Map<String, dynamic>? queryParameters;

  /// The completer resolved by [BatchProcessor] with the parsed response.
  final Completer<dynamic> completer;

  /// Optional deserialization function for the response body.
  final dynamic Function(dynamic json)? fromJson;

  /// Wall-clock time when this entry was added to the batch.
  final DateTime addedAt;

  BatchEntry({
    required this.method,
    required this.path,
    required this.completer,
    this.data,
    this.queryParameters,
    this.fromJson,
  }) : addedAt = DateTime.now();

  /// Serialises to the format expected by the batch endpoint.
  Map<String, dynamic> toJson() => {
        'method': method.toUpperCase(),
        'path': path,
        'query': queryParameters ?? <String, dynamic>{},
        'body': data,
      };

  bool get isCompleted => completer.isCompleted;

  @override
  String toString() =>
      'BatchEntry(${method.toUpperCase()} $path, done: $isCompleted)';
}
