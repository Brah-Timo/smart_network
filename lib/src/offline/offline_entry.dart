import 'dart:convert';
import 'package:dio/dio.dart';

/// Represents a single persisted request in the offline queue.
///
/// All fields must be JSON-serialisable so the entry can be stored in
/// Hive and reconstructed after an app restart.
class OfflineEntry {
  /// The HTTP method (GET, POST, PUT, DELETE, PATCH).
  final String method;

  /// Path (relative to baseUrl) or full URL.
  final String path;

  /// JSON-serialisable request body.
  final dynamic data;

  /// Query parameters appended to the URL.
  final Map<String, dynamic>? queryParameters;

  /// Request-level headers.
  final Map<String, dynamic>? headers;

  /// Extra metadata (e.g. `'tag'` for identifying queue entries).
  final Map<String, dynamic> extra;

  /// When this entry was added to the queue.
  final DateTime queuedAt;

  /// Maximum retry attempts allowed before discarding. `null` = infinite.
  final int? maxRetries;

  /// Number of times this entry has been attempted so far.
  int retryCount;

  OfflineEntry({
    required this.method,
    required this.path,
    this.data,
    this.queryParameters,
    this.headers,
    this.extra = const {},
    DateTime? queuedAt,
    this.maxRetries,
    this.retryCount = 0,
  }) : queuedAt = queuedAt ?? DateTime.now();

  // ── Factory ───────────────────────────────────────────────────────────────

  factory OfflineEntry.fromRequestOptions(RequestOptions options) {
    return OfflineEntry(
      method: options.method,
      path: options.path,
      data: options.data,
      queryParameters: Map<String, dynamic>.from(options.queryParameters),
      headers: Map<String, dynamic>.from(options.headers),
      extra: Map<String, dynamic>.from(options.extra),
    );
  }

  // ── Serialisation ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'method': method,
        'path': path,
        'data': data,
        'queryParameters': queryParameters,
        'headers': headers,
        'extra': extra,
        'queuedAt': queuedAt.millisecondsSinceEpoch,
        'maxRetries': maxRetries,
        'retryCount': retryCount,
      };

  factory OfflineEntry.fromJson(Map<String, dynamic> json) {
    return OfflineEntry(
      method: json['method'] as String,
      path: json['path'] as String,
      data: json['data'],
      queryParameters: json['queryParameters'] != null
          ? Map<String, dynamic>.from(json['queryParameters'] as Map)
          : null,
      headers: json['headers'] != null
          ? Map<String, dynamic>.from(json['headers'] as Map)
          : null,
      extra: json['extra'] != null
          ? Map<String, dynamic>.from(json['extra'] as Map)
          : const {},
      queuedAt: DateTime.fromMillisecondsSinceEpoch(
        json['queuedAt'] as int,
      ),
      maxRetries: json['maxRetries'] as int?,
      retryCount: json['retryCount'] as int? ?? 0,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  static OfflineEntry fromJsonString(String raw) =>
      OfflineEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Rebuilds a [RequestOptions] from this entry (for Dio.fetch).
  RequestOptions toRequestOptions(String baseUrl) {
    return RequestOptions(
      method: method,
      path: path,
      baseUrl: baseUrl,
      data: data,
      queryParameters: queryParameters ?? {},
      headers: headers ?? {},
      extra: extra,
    );
  }

  bool get hasExceededMaxRetries =>
      maxRetries != null && retryCount >= maxRetries!;

  @override
  String toString() => 'OfflineEntry($method $path, '
      'retries: $retryCount/${maxRetries ?? "∞"}, '
      'queuedAt: ${queuedAt.toIso8601String()})';
}
