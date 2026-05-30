import 'dart:convert';

/// A collection of stateless utility functions used across SmartNetwork.
class NetworkUtils {
  NetworkUtils._();

  // ── URL helpers ───────────────────────────────────────────────────────────

  /// Joins [baseUrl] and [path] without double slashes.
  ///
  /// ```dart
  /// NetworkUtils.joinUrl('https://api.example.com/', '/users/1')
  ///   == 'https://api.example.com/users/1'
  /// ```
  static String joinUrl(String baseUrl, String path) {
    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final segment = path.startsWith('/') ? path.substring(1) : path;
    return '$base$segment';
  }

  /// Returns `true` if [url] is an absolute URL (starts with http/https).
  static bool isAbsoluteUrl(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  // ── Query parameter helpers ───────────────────────────────────────────────

  /// Encodes a [Map] as a URL query string.
  ///
  /// Values are recursively encoded; Lists are repeated as `key=v1&key=v2`.
  static String encodeQueryParams(Map<String, dynamic> params) {
    final parts = <String>[];
    params.forEach((key, value) {
      if (value is List) {
        for (final v in value) {
          parts.add(
            '${Uri.encodeQueryComponent(key)}'
            '=${Uri.encodeQueryComponent(v.toString())}',
          );
        }
      } else if (value != null) {
        parts.add(
          '${Uri.encodeQueryComponent(key)}'
          '=${Uri.encodeQueryComponent(value.toString())}',
        );
      }
    });
    return parts.join('&');
  }

  // ── JSON helpers ──────────────────────────────────────────────────────────

  /// Safely decodes a JSON string, returning `null` on any error.
  static dynamic tryDecodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  /// Deep-merges two maps, with [overrides] taking precedence over [base].
  static Map<String, dynamic> mergeHeaders(
    Map<String, dynamic> base,
    Map<String, dynamic> overrides,
  ) {
    return {...base, ...overrides};
  }

  // ── Status code helpers ───────────────────────────────────────────────────

  /// Returns `true` for 2xx status codes.
  static bool isSuccess(int? statusCode) =>
      statusCode != null && statusCode >= 200 && statusCode < 300;

  /// Returns `true` for 4xx status codes.
  static bool isClientError(int? statusCode) =>
      statusCode != null && statusCode >= 400 && statusCode < 500;

  /// Returns `true` for 5xx status codes.
  static bool isServerError(int? statusCode) =>
      statusCode != null && statusCode >= 500 && statusCode < 600;

  // ── Duration helpers ──────────────────────────────────────────────────────

  /// Returns a human-readable representation of a [Duration].
  ///
  /// ```dart
  /// NetworkUtils.formatDuration(Duration(milliseconds: 1500)) == '1.5s'
  /// NetworkUtils.formatDuration(Duration(minutes: 2)) == '2m 0s'
  /// ```
  static String formatDuration(Duration d) {
    if (d.inMinutes >= 1) {
      return '${d.inMinutes}m ${d.inSeconds % 60}s';
    }
    if (d.inSeconds >= 1) {
      return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    }
    return '${d.inMilliseconds}ms';
  }
}
