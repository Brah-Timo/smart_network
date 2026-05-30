import 'dart:async';
import 'dart:convert';
import 'package:synchronized/synchronized.dart';

import 'token_refresher.dart';
import 'token_storage.dart';
import '../core/smart_exception.dart';
import '../utils/logger.dart';

/// Thread-safe manager for JWT access tokens.
///
/// ### Problem solved: Token Refresh Race Condition
/// When an access token expires and multiple requests are in-flight
/// simultaneously, each request would normally trigger an independent
/// refresh call — flooding the auth server and causing token invalidation.
///
/// ### Solution: Double-checked lock + shared Completer
/// ```
/// Thread A → token expired → acquire lock → start refresh
/// Thread B → token expired → lock held → wait for Thread A's Completer
/// Thread C → token expired → lock held → wait for Thread A's Completer
///
/// Thread A finishes → completes Completer → B and C both receive the
///                                            same new token immediately
/// ```
///
/// This ensures at most ONE refresh call per expiry cycle regardless of
/// concurrent request count.
class TokenManager {
  final TokenRefresher _refresher;
  final TokenStorage _storage;
  final SmartLogger _logger;

  /// Mutex that serialises refresh calls.
  final _lock = Lock();

  /// While a refresh is in progress, all subsequent callers await this.
  Completer<TokenPair>? _activeRefreshCompleter;

  /// Clock offset for tests (seconds). Leave 0 in production.
  final int _clockOffsetSeconds;

  TokenManager({
    required TokenRefresher refresher,
    TokenStorage? storage,
    SmartLogger? logger,
    int clockOffsetSeconds = 0,
  })  : _refresher = refresher,
        _storage = storage ?? InMemoryTokenStorage(),
        _logger = logger ?? SmartLogger(),
        _clockOffsetSeconds = clockOffsetSeconds;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Saves [pair] to [TokenStorage].
  Future<void> saveTokens(TokenPair pair) => _storage.saveTokens(pair);

  /// Clears all stored tokens (logout).
  Future<void> clearTokens() => _storage.clearTokens();

  /// Returns a valid access token, refreshing it first if expired.
  ///
  /// Returns `null` if no tokens are stored (not authenticated).
  /// Throws [SmartException] with type [SmartExceptionType.authRefreshFailed]
  /// if the refresh fails.
  Future<String?> getValidAccessToken() async {
    final token = await _storage.getAccessToken();
    if (token == null) return null;

    if (!_isExpired(token)) return token;

    _logger.d('🔑 Access token expired — refreshing...');
    return _refreshSafe();
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  /// Serialises refresh using [_lock] + shared [_activeRefreshCompleter].
  Future<String?> _refreshSafe() async {
    return _lock.synchronized<String?>(() async {
      // Double-check inside the lock — another thread may have refreshed
      final current = await _storage.getAccessToken();
      if (current != null && !_isExpired(current)) {
        _logger.d('🔑 Token already refreshed by another request — reusing.');
        return current;
      }

      // If a refresh Completer already exists, we are mid-refresh —
      // share its future instead of starting a second refresh.
      if (_activeRefreshCompleter != null) {
        final pair = await _activeRefreshCompleter!.future;
        return pair.accessToken;
      }

      return _performRefresh();
    });
  }

  Future<String?> _performRefresh() async {
    _activeRefreshCompleter = Completer<TokenPair>();
    // Attach a no-op error handler so the completer's future is always
    // "listened to". Without this, if no concurrent callers are waiting on
    // _activeRefreshCompleter.future and an error occurs, the rejected future
    // becomes an unhandled error that the test runner reports as a failure.
    // ignore: unawaited_futures
    _activeRefreshCompleter!.future.ignore();

    try {
      final refreshToken = await _storage.getRefreshToken();
      if (refreshToken == null) {
        throw SmartException.authRefreshFailed('No refresh token stored.');
      }

      _logger.d('🔑 Calling TokenRefresher.refresh...');
      final newPair = await _refresher.refresh(refreshToken);

      await _storage.saveTokens(newPair);
      _activeRefreshCompleter!.complete(newPair);

      _logger.i('✅ Token refreshed successfully.');
      return newPair.accessToken;
    } catch (e) {
      // Propagate the error to all waiting callers
      _activeRefreshCompleter!.completeError(
        SmartException.authRefreshFailed(e),
      );
      await _storage.clearTokens();

      _logger.e('❌ Token refresh failed — user must re-authenticate.', error: e);
      throw SmartException.authRefreshFailed(e);
    } finally {
      _activeRefreshCompleter = null;
    }
  }

  // ── JWT helpers ───────────────────────────────────────────────────────────

  /// Decodes the JWT payload and checks the `exp` claim.
  ///
  /// Tokens are considered expired 30 seconds before their actual expiry
  /// to avoid clock-skew races between client and server.
  bool _isExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;

      // Base64url-decode the payload segment
      final normalised = base64Url.normalize(parts[1]);
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(normalised)),
      ) as Map<String, dynamic>;

      final exp = payload['exp'] as int?;
      if (exp == null) return false; // No expiry claim — assume valid

      final expiryUtc =
          DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
      final now = DateTime.now().toUtc().add(
            Duration(seconds: _clockOffsetSeconds),
          );

      // 30-second grace window to avoid last-second expiry race
      return now.isAfter(expiryUtc.subtract(const Duration(seconds: 30)));
    } catch (_) {
      // If we cannot decode the token, treat it as expired
      return true;
    }
  }

  @override
  String toString() => 'TokenManager(refresher: ${_refresher.runtimeType})';
}
