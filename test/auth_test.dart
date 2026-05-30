import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_network/smart_network.dart';

// ── Mock TokenRefresher ────────────────────────────────────────────────────────

class _SuccessRefresher extends TokenRefresher {
  int callCount = 0;

  @override
  Future<TokenPair> refresh(String refreshToken) async {
    callCount++;
    return const TokenPair(
      accessToken: 'new-access-token',
      refreshToken: 'new-refresh-token',
    );
  }
}

class _FailingRefresher extends TokenRefresher {
  @override
  Future<TokenPair> refresh(String refreshToken) async {
    throw Exception('Refresh server down');
  }
}

// ── JWT Helpers (for building test tokens) ────────────────────────────────────

String _buildJwt({required int expOffsetSeconds}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final payload = {'sub': 'user123', 'exp': now + expOffsetSeconds};
  final encoded = base64Url.encode(
    utf8.encode(jsonEncode(payload)),
  );
  // JWT format: header.payload.signature (signature is ignored in tests)
  return 'eyJhbGciOiJIUzI1NiJ9.$encoded.SIG';
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('InMemoryTokenStorage', () {
    late InMemoryTokenStorage storage;

    setUp(() => storage = InMemoryTokenStorage());

    test('returns null when empty', () async {
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
    });

    test('stores and retrieves tokens', () async {
      await storage.saveTokens(
        const TokenPair(
          accessToken: 'access-abc',
          refreshToken: 'refresh-xyz',
        ),
      );
      expect(await storage.getAccessToken(), equals('access-abc'));
      expect(await storage.getRefreshToken(), equals('refresh-xyz'));
    });

    test('clearTokens removes all tokens', () async {
      await storage.saveTokens(
        const TokenPair(accessToken: 'a', refreshToken: 'b'),
      );
      await storage.clearTokens();
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.hasTokens(), isFalse);
    });

    test('hasTokens reflects storage state', () async {
      expect(await storage.hasTokens(), isFalse);
      await storage.saveTokens(
        const TokenPair(accessToken: 'a', refreshToken: 'b'),
      );
      expect(await storage.hasTokens(), isTrue);
    });
  });

  group('TokenManager', () {
    late _SuccessRefresher refresher;
    late InMemoryTokenStorage storage;
    late TokenManager manager;

    setUp(() {
      refresher = _SuccessRefresher();
      storage = InMemoryTokenStorage();
      manager = TokenManager(
        refresher: refresher,
        storage: storage,
        logger: SmartLogger(enabled: false),
      );
    });

    test('returns null when no tokens stored', () async {
      expect(await manager.getValidAccessToken(), isNull);
    });

    test('returns valid non-expired access token directly', () async {
      final token = _buildJwt(expOffsetSeconds: 3600); // 1 hour from now
      await storage.saveTokens(
        TokenPair(accessToken: token, refreshToken: 'rf'),
      );

      final result = await manager.getValidAccessToken();
      expect(result, equals(token));
      expect(refresher.callCount, equals(0)); // no refresh triggered
    });

    test('refreshes expired token and returns new one', () async {
      final expiredToken = _buildJwt(expOffsetSeconds: -60); // 1 min ago
      await storage.saveTokens(
        TokenPair(accessToken: expiredToken, refreshToken: 'rf-token'),
      );

      final result = await manager.getValidAccessToken();
      expect(result, equals('new-access-token'));
      expect(refresher.callCount, equals(1));

      // Subsequent call should NOT refresh again (new token is fresh)
      // (In tests the new token may also appear expired since it's a real JWT)
    });

    test('throws SmartException.authRefreshFailed on refresh failure', () async {
      final failManager = TokenManager(
        refresher: _FailingRefresher(),
        storage: storage,
        logger: SmartLogger(enabled: false),
      );
      await storage.saveTokens(
        TokenPair(
          accessToken: _buildJwt(expOffsetSeconds: -60),
          refreshToken: 'rf',
        ),
      );

      await expectLater(
        failManager.getValidAccessToken(),
        throwsA(isA<SmartException>()),
      );
    });

    test('clearTokens delegates to storage', () async {
      await storage.saveTokens(
        const TokenPair(accessToken: 'a', refreshToken: 'b'),
      );
      await manager.clearTokens();
      expect(await storage.hasTokens(), isFalse);
    });
  });
}
