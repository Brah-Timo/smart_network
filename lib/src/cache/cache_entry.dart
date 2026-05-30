import 'dart:convert';

/// A single entry stored in the cache, wrapping the raw response data
/// alongside metadata needed to evaluate freshness.
class CacheEntry {
  /// The serialised response body (must be JSON-encodable).
  final dynamic data;

  /// The HTTP status code of the cached response.
  final int statusCode;

  /// The response headers stored as a multi-value map.
  final Map<String, List<String>> headers;

  /// When this entry was written to the cache.
  final DateTime cachedAt;

  /// How long this entry is considered fresh.
  final Duration maxAge;

  const CacheEntry({
    required this.data,
    required this.statusCode,
    required this.headers,
    required this.cachedAt,
    required this.maxAge,
  });

  // ── Freshness helpers ────────────────────────────────────────────────────

  /// The instant after which this entry is no longer fresh.
  DateTime get expiresAt => cachedAt.add(maxAge);

  /// True when [DateTime.now] is past [expiresAt].
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// True when the entry is expired but still within the stale window.
  ///
  /// `now < cachedAt + maxAge + staleAge`
  bool isWithinStaleAge(Duration staleAge) {
    final staleDeadline = cachedAt.add(maxAge).add(staleAge);
    return DateTime.now().isBefore(staleDeadline);
  }

  /// Age of this entry at the current moment.
  Duration get age => DateTime.now().difference(cachedAt);

  // ── Serialisation ────────────────────────────────────────────────────────

  /// Serialises the entry to a JSON-compatible Map for Hive storage.
  Map<String, dynamic> toJson() {
    return {
      'data': data,
      'statusCode': statusCode,
      'headers': headers.map(
        (k, v) => MapEntry(k, v),
      ),
      'cachedAt': cachedAt.millisecondsSinceEpoch,
      'maxAgeMs': maxAge.inMilliseconds,
    };
  }

  /// Deserialises a [CacheEntry] from a previously serialised map.
  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'] as Map<String, dynamic>? ?? {};
    final headers = rawHeaders.map(
      (k, v) => MapEntry(
        k,
        (v as List<dynamic>).map((e) => e.toString()).toList(),
      ),
    );

    return CacheEntry(
      data: json['data'],
      statusCode: json['statusCode'] as int,
      headers: headers,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(json['cachedAt'] as int),
      maxAge: Duration(milliseconds: json['maxAgeMs'] as int),
    );
  }

  /// Converts the entry to a JSON string (for Hive string storage).
  String toJsonString() => jsonEncode(toJson());

  /// Deserialises a [CacheEntry] from a JSON string.
  static CacheEntry fromJsonString(String raw) =>
      CacheEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  @override
  String toString() => 'CacheEntry('
      'status: $statusCode, '
      'age: ${age.inSeconds}s, '
      'expired: $isExpired, '
      'cachedAt: ${cachedAt.toIso8601String()})';
}
