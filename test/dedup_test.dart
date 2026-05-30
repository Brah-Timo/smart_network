import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:smart_network/smart_network.dart';

void main() {
  group('RequestDeduplicator', () {
    late RequestDeduplicator dedup;

    setUp(() => dedup = RequestDeduplicator());

    test('registers a pending request', () {
      final completer = Completer<Response<dynamic>>();
      dedup.addPending('key1', PendingRequest(completer: completer));

      expect(dedup.hasPending('key1'), isTrue);
      expect(dedup.pendingCount, equals(1));

      // Prevent unhandled future — consume it
      completer.future.ignore();
    });

    test('returns null for non-existent key', () {
      expect(dedup.getPending('missing'), isNull);
    });

    test('complete resolves the future and removes the entry', () async {
      final completer = Completer<Response<dynamic>>();
      dedup.addPending('key1', PendingRequest(completer: completer));

      final opts = RequestOptions(path: '/test');
      final response = Response<dynamic>(
        requestOptions: opts,
        statusCode: 200,
        data: {'ok': true},
      );

      dedup.complete('key1', response);

      expect(dedup.hasPending('key1'), isFalse);
      expect(await completer.future, equals(response));
    });

    test('completeError rejects the future and removes the entry', () async {
      final completer = Completer<Response<dynamic>>();
      dedup.addPending('key1', PendingRequest(completer: completer));

      dedup.completeError('key1', Exception('Network error'));

      expect(dedup.hasPending('key1'), isFalse);
      await expectLater(
        completer.future,
        throwsA(isA<Exception>()),
      );
    });

    test('completeError is no-op for unknown key', () {
      expect(
        () => dedup.completeError('unknown', Exception('err')),
        returnsNormally,
      );
    });

    test('dispose rejects all pending futures', () async {
      final c1 = Completer<Response<dynamic>>();
      final c2 = Completer<Response<dynamic>>();
      dedup
        ..addPending('k1', PendingRequest(completer: c1))
        ..addPending('k2', PendingRequest(completer: c2));

      dedup.dispose();

      expect(dedup.pendingCount, equals(0));
      await expectLater(c1.future, throwsA(isA<StateError>()));
      await expectLater(c2.future, throwsA(isA<StateError>()));
    });

    test('purgeStale evicts old entries', () async {
      final completer = Completer<Response<dynamic>>();
      // Attach error handler to prevent unhandled TimeoutException when
      // purgeStale completes the completer with an error.
      // ignore: unawaited_futures
      completer.future.ignore();
      final request = PendingRequest(completer: completer);

      // Simulate an old entry by manipulating the creation time indirectly
      // (we rely on age > 0ms)
      dedup.addPending('old', request);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      dedup.purgeStale(Duration.zero);

      expect(dedup.hasPending('old'), isFalse);
      await expectLater(
        completer.future,
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  // ── PendingRequest Tests ───────────────────────────────────────────────────

  group('PendingRequest', () {
    test('isCompleted reflects completer state', () async {
      final completer = Completer<Response<dynamic>>();
      final pending = PendingRequest(completer: completer);

      expect(pending.isCompleted, isFalse);

      completer.complete(
        Response<dynamic>(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 200,
        ),
      );

      expect(pending.isCompleted, isTrue);
    });

    test('age increases over time', () async {
      final pending = PendingRequest(
        completer: Completer<Response<dynamic>>(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(pending.age.inMilliseconds, greaterThan(0));
    });
  });
}
