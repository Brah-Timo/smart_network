import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_network/smart_network.dart';

void main() {
  // ── CacheEntry Tests ───────────────────────────────────────────────────────

  group('CacheEntry', () {
    CacheEntry makeEntry({
      Duration maxAge = const Duration(minutes: 5),
      DateTime? cachedAt,
    }) {
      return CacheEntry(
        data: {'id': 1, 'name': 'Alice'},
        statusCode: 200,
        headers: const {},
        cachedAt: cachedAt ?? DateTime.now(),
        maxAge: maxAge,
      );
    }

    test('isExpired returns false for fresh entry', () {
      final entry = makeEntry();
      expect(entry.isExpired, isFalse);
    });

    test('isExpired returns true for expired entry', () {
      final entry = makeEntry(
        maxAge: const Duration(seconds: 1),
        cachedAt: DateTime.now().subtract(const Duration(seconds: 10)),
      );
      expect(entry.isExpired, isTrue);
    });

    test('isWithinStaleAge returns true within window', () {
      final entry = makeEntry(
        maxAge: const Duration(minutes: 5),
        cachedAt: DateTime.now().subtract(const Duration(minutes: 6)),
      );
      // Entry is expired but within staleAge of 10 minutes
      expect(entry.isExpired, isTrue);
      expect(
        entry.isWithinStaleAge(const Duration(minutes: 10)),
        isTrue,
      );
    });

    test('isWithinStaleAge returns false outside window', () {
      final entry = makeEntry(
        maxAge: const Duration(minutes: 1),
        cachedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      expect(
        entry.isWithinStaleAge(const Duration(minutes: 5)),
        isFalse,
      );
    });

    test('serialisation round-trip preserves data', () {
      final original = makeEntry();
      final json = original.toJson();
      final restored = CacheEntry.fromJson(json);

      expect(restored.statusCode, equals(original.statusCode));
      expect(restored.maxAge, equals(original.maxAge));
      expect(
        restored.cachedAt.millisecondsSinceEpoch,
        equals(original.cachedAt.millisecondsSinceEpoch),
      );
    });

    test('JSON string round-trip works', () {
      final original = makeEntry();
      final jsonStr = original.toJsonString();
      final restored = CacheEntry.fromJsonString(jsonStr);
      expect(restored.statusCode, equals(200));
    });
  });

  // ── MemoryCache Tests ──────────────────────────────────────────────────────

  group('MemoryCache', () {
    late MemoryCache cache;

    CacheEntry freshEntry() => CacheEntry(
          data: 'test',
          statusCode: 200,
          headers: const {},
          cachedAt: DateTime.now(),
          maxAge: const Duration(minutes: 5),
        );

    CacheEntry expiredEntry() => CacheEntry(
          data: 'expired',
          statusCode: 200,
          headers: const {},
          cachedAt: DateTime.now().subtract(const Duration(hours: 1)),
          maxAge: const Duration(minutes: 1),
        );

    setUp(() => cache = MemoryCache(maxEntries: 5));

    test('set and get round-trip', () async {
      await cache.set('key1', freshEntry());
      final retrieved = await cache.get('key1');
      expect(retrieved, isNotNull);
      expect(retrieved!.data, equals('test'));
    });

    test('get returns null for missing key', () async {
      expect(await cache.get('nonexistent'), isNull);
    });

    test('remove deletes entry', () async {
      await cache.set('key1', freshEntry());
      await cache.remove('key1');
      expect(await cache.get('key1'), isNull);
    });

    test('clear empties the cache', () async {
      await cache.set('k1', freshEntry());
      await cache.set('k2', freshEntry());
      await cache.clear();
      expect(await cache.size, equals(0));
    });

    test('LRU eviction when maxEntries reached', () async {
      // Fill to capacity
      for (var i = 0; i < 5; i++) {
        await cache.set('key$i', freshEntry());
      }
      expect(await cache.size, equals(5));

      // Add one more — LRU entry (key0) should be evicted
      await cache.set('key5', freshEntry());
      expect(await cache.size, equals(5));
      expect(await cache.get('key0'), isNull); // evicted
      expect(await cache.get('key5'), isNotNull); // new entry present
    });

    test('accessed entry is moved to end (not evicted)', () async {
      for (var i = 0; i < 5; i++) {
        await cache.set('key$i', freshEntry());
      }
      // Access key0 to make it recently used
      await cache.get('key0');

      // Adding key5 should evict key1 (now the LRU), NOT key0
      await cache.set('key5', freshEntry());
      expect(await cache.get('key0'), isNotNull); // kept
      expect(await cache.get('key1'), isNull); // evicted
    });

    test('evictExpired removes only expired entries', () async {
      await cache.set('fresh', freshEntry());
      await cache.set('expired', expiredEntry());

      final evicted = await cache.evictExpired();
      expect(evicted, equals(1));
      expect(await cache.get('fresh'), isNotNull);
      expect(await cache.get('expired'), isNull);
    });

    test('containsKey returns correct result', () async {
      await cache.set('exists', freshEntry());
      expect(await cache.containsKey('exists'), isTrue);
      expect(await cache.containsKey('missing'), isFalse);
    });
  });

  // ── CachePolicy Tests ──────────────────────────────────────────────────────

  group('CachePolicy', () {
    test('default strategy is staleWhileRevalidate', () {
      const policy = CachePolicy();
      expect(policy.strategy, equals(CacheStrategy.staleWhileRevalidate));
    });

    test('disabled factory disables caching', () {
      expect(CachePolicy.disabled.enabled, isFalse);
    });

    test('copyWith preserves unchanged fields', () {
      const original = CachePolicy(maxAge: Duration(minutes: 10));
      final copy = original.copyWith(strategy: CacheStrategy.cacheFirst);
      expect(copy.maxAge, equals(original.maxAge));
      expect(copy.strategy, equals(CacheStrategy.cacheFirst));
    });
  });

  // ── CacheKeyBuilder Tests ──────────────────────────────────────────────────

  group('CacheKeyBuilder', () {
    RequestOptions _opts(String path, [Map<String, dynamic>? params]) {
      return RequestOptions(
        method: 'GET',
        path: path,
        baseUrl: 'https://api.example.com',
        queryParameters: params ?? {},
      );
    }

    test('same params in different order produce same key', () {
      final key1 = CacheKeyBuilder.build(
        _opts('/users', {'b': '2', 'a': '1'}),
      );
      final key2 = CacheKeyBuilder.build(
        _opts('/users', {'a': '1', 'b': '2'}),
      );
      expect(key1, equals(key2));
    });

    test('different paths produce different keys', () {
      final key1 = CacheKeyBuilder.build(_opts('/users'));
      final key2 = CacheKeyBuilder.build(_opts('/posts'));
      expect(key1, isNot(equals(key2)));
    });

    test('different params produce different keys', () {
      final key1 = CacheKeyBuilder.build(_opts('/users', {'page': '1'}));
      final key2 = CacheKeyBuilder.build(_opts('/users', {'page': '2'}));
      expect(key1, isNot(equals(key2)));
    });

    test('key is a 64-character hex string (SHA-256)', () {
      final key = CacheKeyBuilder.build(_opts('/test'));
      expect(key.length, equals(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);
    });
  });
}
