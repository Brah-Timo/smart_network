import 'package:dio/dio.dart';

import '../auth/token_manager.dart';
import '../core/smart_exception.dart';
import '../utils/logger.dart';

/// Automatically attaches JWT access tokens to outgoing requests and
/// handles 401 responses by refreshing the token and retrying once.
///
/// ### Request flow
/// ```
/// onRequest:
///   1. Call TokenManager.getValidAccessToken()
///      → If expired, refresh happens here (thread-safe)
///   2. Inject Authorization: Bearer <token> header
///
/// onError (401):
///   1. Force-refresh token (ignore cache)
///   2. Retry the original request once with new token
///   3. On second 401: throw SmartExceptionType.unauthorized
/// ```
///
/// ### Per-request opt-out
/// Set `extra['skipAuth'] = true` to skip token injection
/// (e.g. for login / register / public endpoints).
class AuthInterceptor extends Interceptor {
  final TokenManager _tokenManager;
  final Dio _dio;
  final SmartLogger _logger;

  /// Header name for the Bearer token (default: 'Authorization').
  final String headerName;

  /// Token scheme prefix (default: 'Bearer ').
  final String tokenScheme;

  AuthInterceptor({
    required TokenManager tokenManager,
    required Dio dio,
    SmartLogger? logger,
    this.headerName = 'Authorization',
    this.tokenScheme = 'Bearer ',
  })  : _tokenManager = tokenManager,
        _dio = dio,
        _logger = logger ?? SmartLogger();

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Allow callers to opt out of auth for specific requests
    if (options.extra['skipAuth'] == true) {
      return handler.next(options);
    }

    try {
      final token = await _tokenManager.getValidAccessToken();
      if (token != null) {
        options.headers[headerName] = '$tokenScheme$token';
        _logger.d('🔑 Injected $headerName header');
      }
    } on SmartException {
      // Token refresh failed — let the request proceed without a token
      // so the server returns 401 and the error path handles it.
      _logger.w('⚠️ Could not obtain valid token — proceeding unauthenticated');
    }

    return handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.response?.statusCode != 401) {
      return handler.next(err);
    }

    // Prevent infinite refresh loop
    if (err.requestOptions.extra['_isTokenRetry'] == true) {
      _logger.e('❌ 401 on token retry — user must re-authenticate.');
      await _tokenManager.clearTokens();
      return handler.next(err);
    }

    _logger.w(
      '⚠️ 401 received for ${err.requestOptions.path} — '
      'attempting token refresh and retry',
    );

    try {
      // Force a new token (ignore any cached value)
      await _tokenManager.clearTokens();
      final newToken = await _tokenManager.getValidAccessToken();

      if (newToken == null) {
        return handler.next(err);
      }

      // Stamp the retry flag and new token, then re-dispatch
      final retryOptions = err.requestOptions.copyWith(
        headers: Map<String, dynamic>.from(err.requestOptions.headers)
          ..[headerName] = '$tokenScheme$newToken',
        extra: Map<String, dynamic>.from(err.requestOptions.extra)
          ..['_isTokenRetry'] = true,
      );

      final response = await _dio.fetch<dynamic>(retryOptions);
      return handler.resolve(response);
    } on SmartException catch (e) {
      _logger.e('❌ Token refresh failed on 401 retry: $e');
      return handler.next(err);
    } catch (e) {
      _logger.e('❌ Unexpected error during 401 retry: $e');
      return handler.next(err);
    }
  }
}
