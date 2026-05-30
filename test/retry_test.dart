import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:smart_network/smart_network.dart';

// ── Mocks ─────────────────────────────────────────────────────────────────────

class MockDio extends Mock implements Dio {}

// ── Helpers ───────────────────────────────────────────────────────────────────

RequestOptions _opts({String path = '/test', int? retryAttempt}) {
  return RequestOptions(
    path: path,
    method: 'GET',
    extra: {
      'retryAttempt': retryAttempt ?? 0,
      'allowRetry': true,
    },
  );
}

DioException _dioErr(
  RequestOptions opts, {
  DioExceptionType type = DioExceptionType.connectionError,
  int? statusCode,
}) {
  return DioException(
    requestOptions: opts,
    type: type,
    response: statusCode != null
        ? Response(requestOptions: opts, statusCode: statusCode)
        : null,
  );
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── BackoffStrategy Tests ──────────────────────────────────────────────────

  group('BackoffStrategy', () {
    group('ConstantBackoff', () {
      test('always returns the configured delay', () {
        const strategy = ConstantBackoff(delay: Duration(seconds: 3));
        expect(strategy.calculate(0).inSeconds, equals(3));
        expect(strategy.calculate(1).inSeconds, equals(3));
        expect(strategy.calculate(5).inSeconds, equals(3));
      });
    });

    group('LinearBackoff', () {
      test('increases by step each attempt', () {
        const strategy = LinearBackoff(step: Duration(seconds: 2));
        expect(strategy.calculate(0).inSeconds, equals(2)); // 2*1
        expect(strategy.calculate(1).inSeconds, equals(4)); // 2*2
        expect(strategy.calculate(2).inSeconds, equals(6)); // 2*3
      });

      test('caps at maxDelay', () {
        const strategy = LinearBackoff(
          step: Duration(seconds: 10),
          maxDelay: Duration(seconds: 15),
        );
        expect(strategy.calculate(3).inSeconds, equals(15));
      });
    });

    group('ExponentialBackoff', () {
      test('doubles base with each attempt (no jitter)', () {
        const strategy = ExponentialBackoff(
          base: Duration(seconds: 1),
          jitterFactor: 0.0,
        );
        expect(strategy.calculate(0).inMilliseconds, equals(1000)); // 1*2^0
        expect(strategy.calculate(1).inMilliseconds, equals(2000)); // 1*2^1
        expect(strategy.calculate(2).inMilliseconds, equals(4000)); // 1*2^2
        expect(strategy.calculate(3).inMilliseconds, equals(8000)); // 1*2^3
      });

      test('caps at maxDelay', () {
        const strategy = ExponentialBackoff(
          base: Duration(seconds: 1),
          maxDelay: Duration(seconds: 5),
          jitterFactor: 0.0,
        );
        expect(strategy.calculate(10).inSeconds, lessThanOrEqualTo(5));
      });

      test('delay with jitter is within expected range', () {
        const strategy = ExponentialBackoff(
          base: Duration(seconds: 1),
          jitterFactor: 1.0,
        );
        final delay = strategy.calculate(1); // base 2s ± jitter
        expect(delay.inMilliseconds, greaterThanOrEqualTo(2000));
        expect(delay.inMilliseconds, lessThanOrEqualTo(4000));
      });

      test('jitterFactor=0 produces pure exponential (no randomness)', () {
        const strategy = ExponentialBackoff(jitterFactor: 0.0);
        final d1 = strategy.calculate(2);
        final d2 = strategy.calculate(2);
        expect(d1, equals(d2));
      });
    });

    group('DecorrelatedJitterBackoff', () {
      test('produces delays within [base, maxDelay]', () {
        const strategy = DecorrelatedJitterBackoff(
          base: Duration(seconds: 1),
          maxDelay: Duration(seconds: 30),
        );
        for (var i = 0; i < 10; i++) {
          final delay = strategy.calculate(i);
          expect(delay.inSeconds, greaterThanOrEqualTo(1));
          expect(delay.inSeconds, lessThanOrEqualTo(30));
        }
      });
    });
  });

  // ── RetryPolicy Tests ──────────────────────────────────────────────────────

  group('RetryPolicy', () {
    test('default policy has 3 maxAttempts', () {
      const policy = RetryPolicy();
      expect(policy.maxAttempts, equals(3));
    });

    test('none policy disables retries', () {
      expect(RetryPolicy.none.maxAttempts, equals(0));
    });

    test('aggressive policy has 5 maxAttempts', () {
      expect(RetryPolicy.aggressive.maxAttempts, equals(5));
    });
  });

  // ── RetryEvaluator Tests ───────────────────────────────────────────────────

  group('RetryEvaluator', () {
    late RetryEvaluator evaluator;
    const policy = RetryPolicy(
      maxAttempts: 3,
      retryOnStatusCodes: {500, 503},
    );

    setUp(() => evaluator = RetryEvaluator(policy));

    test('returns false when maxAttempts exceeded', () {
      final err = _dioErr(_opts());
      expect(evaluator.shouldRetry(err, 3), isFalse);
      expect(evaluator.shouldRetry(err, 5), isFalse);
    });

    test('returns false when allowRetry is false', () {
      final err = _dioErr(_opts());
      expect(evaluator.shouldRetry(err, 0, allowRetry: false), isFalse);
    });

    test('retries on connection error', () {
      final err = _dioErr(_opts(), type: DioExceptionType.connectionError);
      expect(evaluator.shouldRetry(err, 0), isTrue);
    });

    test('retries on timeout', () {
      final err = _dioErr(_opts(), type: DioExceptionType.receiveTimeout);
      expect(evaluator.shouldRetry(err, 0), isTrue);
    });

    test('retries on matching status codes', () {
      final opts = _opts();
      expect(
        evaluator.shouldRetry(_dioErr(opts, statusCode: 500), 0),
        isTrue,
      );
      expect(
        evaluator.shouldRetry(_dioErr(opts, statusCode: 503), 0),
        isTrue,
      );
    });

    test('does NOT retry on non-matching status codes', () {
      final opts = _opts();
      expect(
        evaluator.shouldRetry(_dioErr(opts, statusCode: 400), 0),
        isFalse,
      );
      expect(
        evaluator.shouldRetry(_dioErr(opts, statusCode: 404), 0),
        isFalse,
      );
    });

    test('doNotRetryOnStatusCodes takes precedence', () {
      const strictPolicy = RetryPolicy(
        retryOnStatusCodes: {500},
        doNotRetryOnStatusCodes: {500},
      );
      final strictEval = RetryEvaluator(strictPolicy);
      expect(
        strictEval.shouldRetry(_dioErr(_opts(), statusCode: 500), 0),
        isFalse,
      );
    });
  });
}
