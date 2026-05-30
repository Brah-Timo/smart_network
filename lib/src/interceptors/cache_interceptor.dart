import 'package:dio/dio.dart';

import '../cache/smart_cache.dart';
import '../cache/cache_entry.dart';
import '../cache/cache_policy.dart';
import '../cache/cache_key_builder.dart';
import '../utils/logger.dart';

/// Intercepts GET requests to apply multi-strategy caching.
///
/// ### Two-layer cache
/// - **L1 (memory)** — [MemoryCache] — sub-millisecond reads, lost on restart.
/// - **L2 (disk)**   — [HiveCache]   — millisecond reads, survives restarts.
///
/// On a cache HIT the interceptor short-circuits the Dio pipeline by
/// calling [RequestInterceptorHandler.resolve], skipping the network entirely.
/// The resolved [Response] has `extra['fromCache'] = true`.
///
/// On a cache MISS or [CacheStrategy.networkOnly] / [CacheStrategy.networkFirst]
/// the request passes through to Dio; [onResponse] then writes the fresh
/// response to both cache layers.
///
/// ### staleWhileRevalidate
/// When a stale-but-within-stale-window entry is found, the interceptor:
/// 1. Resolves immediately with the stale data (fast UX).
/// 2. Fires a background network fetch to refresh the entry.
class CacheInterceptor extends Interceptor {
  final SmartCache _memCache;
  final SmartCache _hiveCache;
  final CachePolicy _policy;
  final SmartLogger _logger;

  // Weak reference to Dio needed for background revalidation
  final Dio _dio;

  CacheInterceptor({
    required SmartCache memoryCache,
    required SmartCache hiveCache,
    required CachePolicy policy,
    required Dio dio,
    SmartLogger? logger,
  })  : _memCache = memoryCache,
        _hiveCache = hiveCache,
        _policy = policy,
        _dio = dio,
        _logger = logger ?? SmartLogger();

  // ── onRequest ─────────────────────────────────────────────────────────────

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Only cache GET requests
    if (!_policy.enabled || options.method != 'GET') {
      return handler.next(options);
    }

    // Per-request override: `extra['useCache'] = false`
    final useCache = options.extra['useCache'] as bool? ?? true;
    if (!useCache) return handler.next(options);

    final cacheKey = CacheKeyBuilder.build(options);
    options.extra['cacheKey'] = cacheKey;

    final entry = await _getFromEitherLayer(cacheKey);

    switch (_policy.strategy) {
      // ── Cache-First ────────────────────────────────────────────────────────
      case CacheStrategy.cacheFirst:
        if (entry != null && !entry.isExpired) {
          _logger.d(
            '📦 [cacheFirst] HIT — key: ${CacheKeyBuilder.buildDebug(options)}',
          );
          return handler.resolve(_buildResponse(entry, options, isStale: false));
        }
        _logger.d('📭 [cacheFirst] MISS — fetching network');
        return handler.next(options);

      // ── Network-First ──────────────────────────────────────────────────────
      case CacheStrategy.networkFirst:
        // Store the fallback entry in extra for onError to use
        options.extra['cachedFallback'] = entry;
        return handler.next(options);

      // ── Network-Only ───────────────────────────────────────────────────────
      case CacheStrategy.networkOnly:
        return handler.next(options);

      // ── Cache-Only ─────────────────────────────────────────────────────────
      case CacheStrategy.cacheOnly:
        if (entry != null) {
          _logger.d(
            '📦 [cacheOnly] Serving — key: ${CacheKeyBuilder.buildDebug(options)}',
          );
          return handler.resolve(_buildResponse(entry, options));
        }
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
            message:
                'CacheOnly: no cached data for "${CacheKeyBuilder.buildDebug(options)}"',
          ),
        );

      // ── Stale-While-Revalidate ─────────────────────────────────────────────
      case CacheStrategy.staleWhileRevalidate:
        if (entry != null) {
          final isFresh = !entry.isExpired;
          final isUsableStale =
              entry.isExpired && entry.isWithinStaleAge(_policy.staleAge);

          if (isFresh || isUsableStale) {
            _logger.d(
              '📦 [swr] ${isFresh ? 'FRESH' : 'STALE'} — '
              'key: ${CacheKeyBuilder.buildDebug(options)}',
            );

            if (isUsableStale) {
              // Fire background revalidation without blocking the caller
              _revalidateBackground(options, cacheKey);
              options.extra['isStale'] = true;
            }

            return handler.resolve(
              _buildResponse(entry, options, isStale: isUsableStale),
            );
          }
        }
        _logger.d(
          '📭 [swr] EXPIRED / MISS — fetching network '
          'for ${CacheKeyBuilder.buildDebug(options)}',
        );
        return handler.next(options);
    }
  }

  // ── onResponse ────────────────────────────────────────────────────────────

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final options = response.requestOptions;

    // Only write successful GET responses to cache
    if (_policy.enabled &&
        options.method == 'GET' &&
        _isSuccessStatus(response.statusCode)) {
      // Skip writing if this is itself a background revalidation request
      if (options.extra['isRevalidation'] == true) {
        return handler.next(response);
      }

      final cacheKey =
          options.extra['cacheKey'] as String? ?? CacheKeyBuilder.build(options);

      final entry = CacheEntry(
        data: response.data,
        statusCode: response.statusCode ?? 200,
        headers: response.headers.map,
        cachedAt: DateTime.now(),
        maxAge: _policy.maxAge,
      );

      await _memCache.set(cacheKey, entry);
      await _hiveCache.set(cacheKey, entry);

      _logger.d(
        '💾 Cached ${CacheKeyBuilder.buildDebug(options)} '
        '(maxAge: ${_policy.maxAge.inMinutes}m)',
      );
    }

    return handler.next(response);
  }

  // ── onError ───────────────────────────────────────────────────────────────

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // For networkFirst: fall back to cache on any network error
    if (_policy.strategy == CacheStrategy.networkFirst) {
      final fallback =
          err.requestOptions.extra['cachedFallback'] as CacheEntry?;
      if (fallback != null) {
        _logger.w(
          '⚠️ [networkFirst] Network failed — serving stale cache for '
          '${CacheKeyBuilder.buildDebug(err.requestOptions)}',
        );
        return handler.resolve(
          _buildResponse(fallback, err.requestOptions, isStale: true),
        );
      }
    }
    return handler.next(err);
  }

  // ── Private Helpers ───────────────────────────────────────────────────────

  /// Reads from L1 first; promotes to L1 if found only in L2.
  Future<CacheEntry?> _getFromEitherLayer(String key) async {
    var entry = await _memCache.get(key);
    if (entry != null) return entry;

    entry = await _hiveCache.get(key);
    if (entry != null) {
      // Promote to L1 for faster access next time
      await _memCache.set(key, entry);
    }
    return entry;
  }

  Response<dynamic> _buildResponse(
    CacheEntry entry,
    RequestOptions options, {
    bool isStale = false,
  }) {
    return Response<dynamic>(
      requestOptions: options,
      data: entry.data,
      statusCode: entry.statusCode,
      headers: Headers.fromMap(entry.headers),
      extra: {
        'fromCache': true,
        'isStale': isStale,
        'cachedAt': entry.cachedAt.toIso8601String(),
      },
    );
  }

  void _revalidateBackground(RequestOptions original, String cacheKey) {
    Future.microtask(() async {
      try {
        _logger.d(
          '🔄 Background revalidation for '
          '${CacheKeyBuilder.buildDebug(original)}',
        );
        final refreshOptions = original.copyWith(
          extra: Map<String, dynamic>.from(original.extra)
            ..['isRevalidation'] = true
            ..['useCache'] = false,
        );
        await _dio.fetch<dynamic>(refreshOptions);
        _logger.d(
          '✅ Revalidation complete for ${CacheKeyBuilder.buildDebug(original)}',
        );
      } catch (e) {
        _logger.w('⚠️ Background revalidation failed: $e');
      }
    });
  }

  bool _isSuccessStatus(int? code) => code != null && code >= 200 && code < 300;
}
