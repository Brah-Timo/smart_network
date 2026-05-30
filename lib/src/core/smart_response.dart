import 'package:equatable/equatable.dart';

/// The unified, type-safe response wrapper returned by [SmartNetworkClient].
///
/// Type parameter [T] is the deserialized body type. When `fromJson` is
/// provided to a request method, [data] will be of that type; otherwise
/// it is the raw `dynamic` value from Dio.
///
/// Example:
/// ```dart
/// final res = await client.get<User>('/me', fromJson: User.fromJson);
/// if (res.isSuccess) {
///   print(res.data.name);           // T = User
///   print('From cache: ${res.fromCache}');
/// }
/// ```
class SmartResponse<T> extends Equatable {
  /// The deserialized response body.
  final T data;

  /// HTTP status code (e.g. 200, 201, 204).
  final int statusCode;

  /// Response headers as a multi-value map.
  final Map<String, List<String>> headers;

  /// True when the response was served from cache rather than the network.
  final bool fromCache;

  /// True when the data is stale (served from cache while revalidating in
  /// background). Only relevant with [CacheStrategy.staleWhileRevalidate].
  final bool isStale;

  /// True when this response represents a request that has been queued
  /// for later execution (offline mode).
  final bool isQueued;

  /// Timestamp when this response object was created.
  final DateTime receivedAt;

  SmartResponse({
    required this.data,
    required this.statusCode,
    required this.headers,
    this.fromCache = false,
    this.isStale = false,
    this.isQueued = false,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  // ── Convenience Getters ──────────────────────────────────────────────────

  /// True for 2xx status codes.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// True for 4xx status codes.
  bool get isClientError => statusCode >= 400 && statusCode < 500;

  /// True for 5xx status codes.
  bool get isServerError => statusCode >= 500 && statusCode < 600;

  /// Returns the value of a single-value header (case-insensitive key).
  String? header(String key) =>
      headers.entries
          .firstWhere(
            (e) => e.key.toLowerCase() == key.toLowerCase(),
            orElse: () => const MapEntry('', []),
          )
          .value
          .firstOrNull;

  /// Returns the Content-Type header value if present.
  String? get contentType => header('content-type');

  /// Transforms [data] using the provided [mapper] function.
  SmartResponse<R> map<R>(R Function(T data) mapper) {
    return SmartResponse<R>(
      data: mapper(data),
      statusCode: statusCode,
      headers: headers,
      fromCache: fromCache,
      isStale: isStale,
      isQueued: isQueued,
      receivedAt: receivedAt,
    );
  }

  @override
  List<Object?> get props => [
        data,
        statusCode,
        headers,
        fromCache,
        isStale,
        isQueued,
        receivedAt,
      ];

  @override
  String toString() => 'SmartResponse<$T>('
      'status: $statusCode, '
      'fromCache: $fromCache, '
      'isStale: $isStale, '
      'isQueued: $isQueued, '
      'at: ${receivedAt.toIso8601String()}'
      ')';
}
