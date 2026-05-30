import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

/// Builds deterministic, collision-resistant cache keys from [RequestOptions].
///
/// The key is constructed from:
/// 1. HTTP method (uppercased)
/// 2. Full URL (baseUrl + path)
/// 3. Sorted query parameters
/// 4. Optionally: selected request headers (e.g. `Accept-Language`)
///
/// The result is SHA-256 hashed to produce a fixed-length, filesystem-safe
/// string that can be used directly as a Hive or in-memory map key.
///
/// ### Example
/// ```
/// GET https://api.example.com/users?limit=10&page=1
///   → SHA-256 → "a3f1c7...e8d2"
/// ```
class CacheKeyBuilder {
  /// Headers whose values are included in the key (case-insensitive).
  ///
  /// This is useful when the same endpoint returns different content
  /// per locale or content type.
  static const defaultKeyHeaders = <String>[
    'accept-language',
    'accept',
  ];

  /// Builds a cache key for the given [options].
  ///
  /// [extraHeaders] optionally adds more header names to the key.
  static String build(
    RequestOptions options, {
    List<String> extraHeaders = const [],
  }) {
    final buffer = StringBuffer();

    // 1. Method
    buffer.write(options.method.toUpperCase());
    buffer.write(':');

    // 2. Full URL (normalised)
    final uri = options.uri;
    buffer.write(uri.scheme);
    buffer.write('://');
    buffer.write(uri.host);
    if (uri.hasPort &&
        uri.port != 80 &&
        uri.port != 443) {
      buffer.write(':${uri.port}');
    }
    buffer.write(uri.path);

    // 3. Query parameters — sorted for order-independence
    final params = Map<String, dynamic>.from(options.queryParameters);
    if (params.isNotEmpty) {
      final sortedKeys = params.keys.toList()..sort();
      buffer.write('?');
      buffer.write(
        sortedKeys.map((k) => '$k=${params[k]}').join('&'),
      );
    }

    // 4. Selected headers
    final allKeyHeaders = {...defaultKeyHeaders, ...extraHeaders};
    final headers = options.headers;
    for (final name in allKeyHeaders) {
      final value = headers.entries
          .firstWhere(
            (e) => e.key.toLowerCase() == name.toLowerCase(),
            orElse: () => const MapEntry('', null),
          )
          .value;
      if (value != null) {
        buffer.write('|$name=$value');
      }
    }

    // 5. Hash to fixed-length string
    final bytes = utf8.encode(buffer.toString());
    return sha256.convert(bytes).toString();
  }

  /// Builds a human-readable (un-hashed) key for debugging purposes.
  static String buildDebug(RequestOptions options) {
    final params = options.queryParameters;
    final sortedParams = Map.fromEntries(
      params.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final query = sortedParams.entries
        .map((e) => '${e.key}=${e.value}')
        .join('&');

    return '${options.method.toUpperCase()}:${options.uri.path}'
        '${query.isNotEmpty ? '?$query' : ''}';
  }
}
