/// A pair of JWT tokens returned by the auth server.
class TokenPair {
  /// Short-lived access token used in Authorization headers.
  final String accessToken;

  /// Long-lived refresh token used to obtain new access tokens.
  final String refreshToken;

  /// Optional expiry hint from the server (seconds from now).
  final int? expiresIn;

  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    this.expiresIn,
  });

  @override
  String toString() => 'TokenPair(expires_in: $expiresIn)';
}

/// Contract that the host application must implement to teach
/// SmartNetwork how to refresh expired tokens.
///
/// SmartNetwork calls [refresh] exactly once per expiry cycle (thread-safe).
/// Implement this in your application:
///
/// ```dart
/// class MyTokenRefresher implements TokenRefresher {
///   @override
///   Future<TokenPair> refresh(String refreshToken) async {
///     final res = await http.post(
///       Uri.parse('https://api.example.com/auth/refresh'),
///       body: {'refresh_token': refreshToken},
///     );
///     final json = jsonDecode(res.body);
///     return TokenPair(
///       accessToken: json['access_token'],
///       refreshToken: json['refresh_token'],
///       expiresIn: json['expires_in'],
///     );
///   }
/// }
/// ```
abstract class TokenRefresher {
  const TokenRefresher();

  /// Called when the current access token has expired.
  ///
  /// Must return a new [TokenPair] on success.
  /// Throw any exception to signal that re-authentication is required.
  Future<TokenPair> refresh(String refreshToken);
}
