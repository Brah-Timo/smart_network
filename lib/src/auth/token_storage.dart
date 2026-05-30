import 'token_refresher.dart';

/// Abstract interface for persisting and retrieving token pairs.
///
/// The default implementation [InMemoryTokenStorage] stores tokens in
/// RAM for testing and development. In production, replace with a
/// Secure Storage backend (e.g. `flutter_secure_storage`).
///
/// Example (production):
/// ```dart
/// class SecureTokenStorage implements TokenStorage {
///   final _storage = const FlutterSecureStorage();
///
///   @override
///   Future<void> saveTokens(TokenPair pair) async {
///     await _storage.write(key: 'access_token', value: pair.accessToken);
///     await _storage.write(key: 'refresh_token', value: pair.refreshToken);
///   }
///
///   @override
///   Future<String?> getAccessToken() => _storage.read(key: 'access_token');
///
///   @override
///   Future<String?> getRefreshToken() => _storage.read(key: 'refresh_token');
///
///   @override
///   Future<void> clearTokens() async {
///     await _storage.delete(key: 'access_token');
///     await _storage.delete(key: 'refresh_token');
///   }
/// }
/// ```
abstract class TokenStorage {
  const TokenStorage();

  /// Persists [pair] to storage.
  Future<void> saveTokens(TokenPair pair);

  /// Returns the stored access token, or `null` if none.
  Future<String?> getAccessToken();

  /// Returns the stored refresh token, or `null` if none.
  Future<String?> getRefreshToken();

  /// Clears both tokens (called on logout or auth failure).
  Future<void> clearTokens();

  /// Checks whether any tokens are currently stored.
  Future<bool> hasTokens() async {
    return (await getAccessToken()) != null;
  }
}

/// Default in-memory storage — suitable for testing and short-lived sessions.
///
/// ⚠️  Tokens are lost when the app is killed. Use a secure storage
/// implementation in production.
class InMemoryTokenStorage extends TokenStorage {
  String? _accessToken;
  String? _refreshToken;

  @override
  Future<void> saveTokens(TokenPair pair) async {
    _accessToken = pair.accessToken;
    _refreshToken = pair.refreshToken;
  }

  @override
  Future<String?> getAccessToken() async => _accessToken;

  @override
  Future<String?> getRefreshToken() async => _refreshToken;

  @override
  Future<void> clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
  }

  @override
  String toString() =>
      'InMemoryTokenStorage(hasToken: ${_accessToken != null})';
}
