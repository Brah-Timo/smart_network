import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:smart_network/smart_network.dart';

// ── Mocks ─────────────────────────────────────────────────────────────────────

class MockDio extends Mock implements Dio {}

// ── Helpers ───────────────────────────────────────────────────────────────────

Response<dynamic> _batchResponse(List<Map<String, dynamic>> items) {
  return Response<dynamic>(
    requestOptions: RequestOptions(path: '/batch'),
    statusCode: 200,
    data: {'responses': items},
  );
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    registerFallbackValue(RequestOptions(path: '/'));
    registerFallbackValue(Options());
  });

  group('BatchConfig', () {
    test('default values are sensible', () {
      const config = BatchConfig(batchEndpoint: '/batch');
      expect(config.maxBatchSize, equals(10));
      expect(config.windowDuration.inMilliseconds, equals(50));
    });

    test('maxBatchSize must be positive', () {
      expect(
        () => BatchConfig(batchEndpoint: '/b', maxBatchSize: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('BatchEntry', () {
    test('toJson produces correct structure', () {
      final entry = BatchEntry(
        method: 'GET',
        path: '/users/1',
        completer: Completer<dynamic>(),
        queryParameters: {'include': 'profile'},
      );

      final json = entry.toJson();
      expect(json['method'], equals('GET'));
      expect(json['path'], equals('/users/1'));
      expect(json['query'], equals({'include': 'profile'}));
    });

    test('isCompleted reflects completer state', () {
      final completer = Completer<dynamic>();
      final entry = BatchEntry(
        method: 'GET',
        path: '/test',
        completer: completer,
      );
      expect(entry.isCompleted, isFalse);
      completer.complete('result');
      expect(entry.isCompleted, isTrue);
    });
  });

  group('BatchProcessor', () {
    late MockDio mockDio;
    late BatchProcessor processor;

    const config = BatchConfig(
      batchEndpoint: '/batch',
      maxBatchSize: 3,
      windowDuration: Duration(milliseconds: 20),
    );

    setUp(() {
      mockDio = MockDio();
      processor = BatchProcessor(
        dio: mockDio,
        config: config,
        logger: SmartLogger(enabled: false),
      );
    });

    tearDown(() => processor.dispose());

    test('dispatches batch on window expiry', () async {
      when(() => mockDio.post<dynamic>(any(), data: any(named: 'data'),
              options: any(named: 'options')))
          .thenAnswer(
        (_) async => _batchResponse([
          {'status': 200, 'body': 'result-1'},
          {'status': 200, 'body': 'result-2'},
        ]),
      );

      final f1 = processor.addRequest<String>(path: '/a', method: 'GET');
      final f2 = processor.addRequest<String>(path: '/b', method: 'GET');

      final results = await Future.wait([f1, f2]);
      expect(results, equals(['result-1', 'result-2']));

      verify(
        () => mockDio.post<dynamic>(any(), data: any(named: 'data'),
            options: any(named: 'options')),
      ).called(1);
    });

    test('flushes immediately when maxBatchSize reached', () async {
      when(() => mockDio.post<dynamic>(any(), data: any(named: 'data'),
              options: any(named: 'options')))
          .thenAnswer(
        (_) async => _batchResponse([
          {'status': 200, 'body': 'r1'},
          {'status': 200, 'body': 'r2'},
          {'status': 200, 'body': 'r3'},
        ]),
      );

      final futures = [
        processor.addRequest<String>(path: '/1', method: 'GET'),
        processor.addRequest<String>(path: '/2', method: 'GET'),
        processor.addRequest<String>(path: '/3', method: 'GET'), // triggers flush
      ];

      final results = await Future.wait(futures);
      expect(results.length, equals(3));
    });

    test('rejects all entries when server returns error', () async {
      when(() => mockDio.post<dynamic>(any(), data: any(named: 'data'),
              options: any(named: 'options')))
          .thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/batch'),
          message: 'Server down',
        ),
      );

      final f = processor.addRequest<String>(path: '/a', method: 'GET');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await expectLater(f, throwsA(isA<DioException>()));
    });

    test('dispose rejects all pending requests', () async {
      // Don't set up any mock response so the timer won't fire
      final f = processor.addRequest<String>(path: '/x', method: 'GET');
      processor.dispose();
      await expectLater(f, throwsA(isA<StateError>()));
    });

    test('addRequest after dispose returns error', () async {
      processor.dispose();
      final f = processor.addRequest<String>(path: '/x', method: 'GET');
      await expectLater(f, throwsA(isA<StateError>()));
    });
  });
}
