import 'package:equatable/equatable.dart';

/// Supported HTTP methods.
enum HttpMethod {
  get,
  post,
  put,
  delete,
  patch,
  head,
  options;

  /// Returns the uppercase string representation used by Dio.
  String get value => name.toUpperCase();
}

/// Represents a single outgoing network request before it is dispatched.
///
/// Interceptors read from and write to [extra] to pass metadata along
/// the chain without polluting the public API.
///
/// Example:
/// ```dart
/// final req = SmartRequest(
///   method: HttpMethod.get,
///   path: '/users/42',
///   queryParameters: {'include': 'profile'},
///   useCache: true,
///   allowRetry: true,
/// );
/// ```
class SmartRequest extends Equatable {
  /// HTTP verb for this request.
  final HttpMethod method;

  /// Path relative to [SmartConfig.baseUrl].
  /// May be an absolute URL if it starts with 'http'.
  final String path;

  /// Request body — a Map, List, FormData, or raw bytes.
  final dynamic data;

  /// URL query parameters appended to [path].
  final Map<String, dynamic>? queryParameters;

  /// Per-request headers that override [SmartConfig.defaultHeaders].
  final Map<String, dynamic>? headers;

  /// Arbitrary metadata threaded through the interceptor chain.
  ///
  /// Built-in keys (set/read by interceptors):
  /// - `'retryAttempt'` (int)  — current retry count
  /// - `'dedupKey'`    (String) — deduplication fingerprint
  /// - `'cacheKey'`   (String) — computed cache key
  /// - `'fromCache'`  (bool)   — whether response came from cache
  /// - `'isStale'`    (bool)   — whether cached response is stale
  /// - `'queueIfOffline'` (bool) — persist when offline
  final Map<String, dynamic> extra;

  /// Allow the cache interceptor to serve/store this request (default: true).
  /// Ignored for non-GET methods (writes are never cached).
  final bool useCache;

  /// Allow the retry interceptor to retry this request on failure (default: true).
  final bool allowRetry;

  /// Persist this request to disk when offline and replay on reconnect.
  ///
  /// Recommended only for state-mutating requests (POST / PUT / DELETE)
  /// that must not be lost.
  final bool queueIfOffline;

  /// Milliseconds before this specific request times out.
  /// Overrides [SmartConfig.receiveTimeout] when set.
  final Duration? timeout;

  const SmartRequest({
    required this.method,
    required this.path,
    this.data,
    this.queryParameters,
    this.headers,
    this.extra = const {},
    this.useCache = true,
    this.allowRetry = true,
    this.queueIfOffline = false,
    this.timeout,
  });

  // ── Computed Properties ──────────────────────────────────────────────────

  /// A deterministic, order-independent fingerprint for this request.
  ///
  /// Used by the deduplication and cache interceptors to identify
  /// logically identical requests regardless of parameter order.
  String get uniqueKey {
    final buffer = StringBuffer()
      ..write(method.value)
      ..write(':')
      ..write(path);

    if (queryParameters != null && queryParameters!.isNotEmpty) {
      final sorted = Map.fromEntries(
        queryParameters!.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)),
      );
      buffer
        ..write('?')
        ..write(
          sorted.entries.map((e) => '${e.key}=${e.value}').join('&'),
        );
    }

    return buffer.toString();
  }

  /// Whether this request should be eligible for offline queuing.
  /// Only POST / PUT / DELETE / PATCH are queued by default.
  bool get isQueueable =>
      queueIfOffline &&
      (method == HttpMethod.post ||
          method == HttpMethod.put ||
          method == HttpMethod.delete ||
          method == HttpMethod.patch);

  /// Merges [extra] with the built-in offline flag for Dio's options.
  Map<String, dynamic> get resolvedExtra => {
        'allowRetry': allowRetry,
        'useCache': useCache,
        'queueIfOffline': queueIfOffline,
        ...extra,
      };

  SmartRequest copyWith({
    HttpMethod? method,
    String? path,
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? extra,
    bool? useCache,
    bool? allowRetry,
    bool? queueIfOffline,
    Duration? timeout,
  }) {
    return SmartRequest(
      method: method ?? this.method,
      path: path ?? this.path,
      data: data ?? this.data,
      queryParameters: queryParameters ?? this.queryParameters,
      headers: headers ?? this.headers,
      extra: extra ?? this.extra,
      useCache: useCache ?? this.useCache,
      allowRetry: allowRetry ?? this.allowRetry,
      queueIfOffline: queueIfOffline ?? this.queueIfOffline,
      timeout: timeout ?? this.timeout,
    );
  }

  @override
  List<Object?> get props => [
        method,
        path,
        data,
        queryParameters,
        headers,
        extra,
        useCache,
        allowRetry,
        queueIfOffline,
        timeout,
      ];

  @override
  String toString() =>
      'SmartRequest(${method.value} $path, cache: $useCache, retry: $allowRetry, offline: $queueIfOffline)';
}
