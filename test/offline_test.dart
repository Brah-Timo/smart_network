import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:smart_network/smart_network.dart';

void main() {
  // ── OfflineEntry Tests ─────────────────────────────────────────────────────

  group('OfflineEntry', () {
    OfflineEntry makeEntry({
      String method = 'POST',
      String path = '/posts',
      int? maxRetries,
    }) {
      return OfflineEntry(
        method: method,
        path: path,
        data: {'title': 'Hello'},
        maxRetries: maxRetries,
      );
    }

    test('serialisation round-trip', () {
      final entry = makeEntry(maxRetries: 3);
      final json = entry.toJson();
      final restored = OfflineEntry.fromJson(json);

      expect(restored.method, equals(entry.method));
      expect(restored.path, equals(entry.path));
      expect(restored.maxRetries, equals(3));
      expect(restored.retryCount, equals(0));
    });

    test('JSON string round-trip', () {
      final entry = makeEntry();
      final restored = OfflineEntry.fromJsonString(entry.toJsonString());
      expect(restored.path, equals('/posts'));
    });

    test('fromRequestOptions captures method and path', () {
      final opts = RequestOptions(
        method: 'PUT',
        path: '/users/1',
        data: {'name': 'Bob'},
      );
      final entry = OfflineEntry.fromRequestOptions(opts);
      expect(entry.method, equals('PUT'));
      expect(entry.path, equals('/users/1'));
    });

    test('hasExceededMaxRetries is false initially', () {
      expect(makeEntry(maxRetries: 3).hasExceededMaxRetries, isFalse);
    });

    test('hasExceededMaxRetries is true when limit reached', () {
      final entry = makeEntry(maxRetries: 2);
      entry.retryCount = 2;
      expect(entry.hasExceededMaxRetries, isTrue);
    });

    test('null maxRetries means unlimited retries', () {
      final entry = makeEntry();
      entry.retryCount = 1000;
      expect(entry.hasExceededMaxRetries, isFalse);
    });

    test('toRequestOptions builds correct Dio options', () {
      final entry = makeEntry(method: 'DELETE', path: '/items/5');
      final opts = entry.toRequestOptions('https://api.example.com');
      expect(opts.method, equals('DELETE'));
      expect(opts.path, equals('/items/5'));
    });
  });

  // ── SmartException Tests ───────────────────────────────────────────────────

  group('SmartException', () {
    test('fromDioException maps connectionError to noInternet', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      );
      final smartErr = SmartException.fromDioException(err);
      expect(smartErr.type, equals(SmartExceptionType.noInternet));
    });

    test('fromDioException maps timeout types', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        final err = DioException(
          requestOptions: RequestOptions(path: '/'),
          type: type,
        );
        expect(
          SmartException.fromDioException(err).type,
          equals(SmartExceptionType.timeout),
        );
      }
    });

    test('fromDioException maps 401 to unauthorized', () {
      final opts = RequestOptions(path: '/');
      final err = DioException(
        requestOptions: opts,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: opts, statusCode: 401),
      );
      expect(
        SmartException.fromDioException(err).type,
        equals(SmartExceptionType.unauthorized),
      );
    });

    test('fromDioException maps 500 to serverError', () {
      final opts = RequestOptions(path: '/');
      final err = DioException(
        requestOptions: opts,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: opts, statusCode: 500),
      );
      expect(
        SmartException.fromDioException(err).type,
        equals(SmartExceptionType.serverError),
      );
    });

    test('isRetryable returns true for noInternet', () {
      const e = SmartException(
        message: 'no internet',
        type: SmartExceptionType.noInternet,
      );
      expect(e.isRetryable, isTrue);
    });

    test('isAuthError returns true for unauthorized and authRefreshFailed', () {
      const e1 = SmartException(
        message: '',
        type: SmartExceptionType.unauthorized,
      );
      const e2 = SmartException(
        message: '',
        type: SmartExceptionType.authRefreshFailed,
      );
      expect(e1.isAuthError, isTrue);
      expect(e2.isAuthError, isTrue);
    });

    test('cacheNotFound factory sets correct type', () {
      final e = SmartException.cacheNotFound('/profile');
      expect(e.type, equals(SmartExceptionType.cacheNotFound));
      expect(e.requestPath, equals('/profile'));
    });
  });

  // ── NetworkUtils Tests ─────────────────────────────────────────────────────

  group('NetworkUtils', () {
    test('joinUrl handles trailing/leading slashes correctly', () {
      expect(
        NetworkUtils.joinUrl('https://api.example.com/', '/users'),
        equals('https://api.example.com/users'),
      );
      expect(
        NetworkUtils.joinUrl('https://api.example.com', 'users'),
        equals('https://api.example.com/users'),
      );
    });

    test('isAbsoluteUrl identifies absolute URLs', () {
      expect(NetworkUtils.isAbsoluteUrl('https://example.com'), isTrue);
      expect(NetworkUtils.isAbsoluteUrl('http://example.com'), isTrue);
      expect(NetworkUtils.isAbsoluteUrl('/relative/path'), isFalse);
      expect(NetworkUtils.isAbsoluteUrl('relative'), isFalse);
    });

    test('isSuccess, isClientError, isServerError work correctly', () {
      expect(NetworkUtils.isSuccess(200), isTrue);
      expect(NetworkUtils.isSuccess(201), isTrue);
      expect(NetworkUtils.isSuccess(299), isTrue);
      expect(NetworkUtils.isSuccess(300), isFalse);

      expect(NetworkUtils.isClientError(400), isTrue);
      expect(NetworkUtils.isClientError(499), isTrue);
      expect(NetworkUtils.isClientError(500), isFalse);

      expect(NetworkUtils.isServerError(500), isTrue);
      expect(NetworkUtils.isServerError(503), isTrue);
      expect(NetworkUtils.isServerError(404), isFalse);
    });

    test('formatDuration formats correctly', () {
      expect(
        NetworkUtils.formatDuration(const Duration(milliseconds: 500)),
        equals('500ms'),
      );
      expect(
        NetworkUtils.formatDuration(const Duration(seconds: 2)),
        equals('2.0s'),
      );
      expect(
        NetworkUtils.formatDuration(const Duration(minutes: 1, seconds: 30)),
        equals('1m 30s'),
      );
    });

    test('mergeHeaders overrides base with override values', () {
      final base = {'Accept': 'application/json', 'X-App': 'v1'};
      final overrides = {'Accept': 'text/plain', 'X-Custom': 'yes'};
      final merged = NetworkUtils.mergeHeaders(base, overrides);
      expect(merged['Accept'], equals('text/plain')); // overridden
      expect(merged['X-App'], equals('v1')); // preserved
      expect(merged['X-Custom'], equals('yes')); // added
    });
  });
}
