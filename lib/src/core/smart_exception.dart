import 'dart:io';
import 'package:dio/dio.dart';

/// Categorises all possible failure modes from SmartNetwork.
enum SmartExceptionType {
  /// Device has no internet connectivity.
  noInternet,

  /// Request timed out (connect, send, or receive).
  timeout,

  /// Server returned a 5xx response.
  serverError,

  /// Server returned 401 — token missing or expired.
  unauthorized,

  /// Server returned 403 — insufficient permissions.
  forbidden,

  /// Server returned 404 — resource does not exist.
  notFound,

  /// Server returned 429 — rate limit exceeded.
  tooManyRequests,

  /// Request was cancelled by the caller.
  cancelled,

  /// Response body could not be parsed into the expected type.
  parseError,

  /// Token refresh failed — user must re-authenticate.
  authRefreshFailed,

  /// No cached data found when [CacheStrategy.cacheOnly] was used.
  cacheNotFound,

  /// An unexpected error not covered by the categories above.
  unknown,
}

/// A unified exception thrown by [SmartNetworkClient] for all failure modes.
///
/// Catches [DioException] and translates it into a human-readable,
/// type-safe [SmartException] so callers do NOT need to import Dio.
///
/// Example:
/// ```dart
/// try {
///   final res = await client.get('/users/1');
/// } on SmartException catch (e) {
///   switch (e.type) {
///     case SmartExceptionType.noInternet:
///       showOfflineBanner();
///     case SmartExceptionType.unauthorized:
///       navigateToLogin();
///     default:
///       showError(e.message);
///   }
/// }
/// ```
class SmartException implements Exception {
  /// Human-readable description of what went wrong.
  final String message;

  /// The category of failure — use this for branching logic.
  final SmartExceptionType type;

  /// The HTTP status code, if applicable.
  final int? statusCode;

  /// The request path that caused the exception.
  final String? requestPath;

  /// The number of retry attempts that were made before giving up.
  final int? retryAttempts;

  /// The raw underlying error (DioException, SocketException, etc.).
  final dynamic rawError;

  const SmartException({
    required this.message,
    required this.type,
    this.statusCode,
    this.requestPath,
    this.retryAttempts,
    this.rawError,
  });

  // ── Factory Constructors ─────────────────────────────────────────────────

  /// Translates a [DioException] into a [SmartException].
  factory SmartException.fromDioException(
    DioException e, {
    int? retryAttempts,
  }) {
    final path = e.requestOptions.path;

    switch (e.type) {
      case DioExceptionType.connectionError:
        final isSocket = e.error is SocketException;
        return SmartException(
          message: isSocket
              ? 'No internet connection. Please check your network.'
              : 'Connection error: ${e.message ?? 'unknown'}',
          type: SmartExceptionType.noInternet,
          requestPath: path,
          retryAttempts: retryAttempts,
          rawError: e,
        );

      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return SmartException(
          message: 'Request timed out after '
              '${e.requestOptions.receiveTimeout?.inSeconds ?? '?'}s. '
              'Please try again.',
          type: SmartExceptionType.timeout,
          requestPath: path,
          retryAttempts: retryAttempts,
          rawError: e,
        );

      case DioExceptionType.cancel:
        return SmartException(
          message: 'Request was cancelled.',
          type: SmartExceptionType.cancelled,
          requestPath: path,
          rawError: e,
        );

      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        return SmartException(
          message: _messageFromStatus(code, e),
          type: _typeFromStatus(code),
          statusCode: code,
          requestPath: path,
          retryAttempts: retryAttempts,
          rawError: e,
        );

      case DioExceptionType.badCertificate:
        return SmartException(
          message: 'SSL certificate validation failed.',
          type: SmartExceptionType.unknown,
          requestPath: path,
          rawError: e,
        );

      default:
        return SmartException(
          message: e.message ?? 'An unexpected network error occurred.',
          type: SmartExceptionType.unknown,
          requestPath: path,
          retryAttempts: retryAttempts,
          rawError: e,
        );
    }
  }

  /// Creates a [SmartException] for failed JSON parsing.
  factory SmartException.parseError({
    required String path,
    required dynamic rawError,
  }) {
    return SmartException(
      message: 'Failed to parse server response. '
          'The API may have changed its schema.',
      type: SmartExceptionType.parseError,
      requestPath: path,
      rawError: rawError,
    );
  }

  /// Creates a [SmartException] for cache-miss under cacheOnly strategy.
  factory SmartException.cacheNotFound(String path) {
    return SmartException(
      message: 'No cached data found for "$path". '
          'Consider switching to a network-aware cache strategy.',
      type: SmartExceptionType.cacheNotFound,
      requestPath: path,
    );
  }

  /// Creates a [SmartException] when token refresh fails permanently.
  factory SmartException.authRefreshFailed(dynamic cause) {
    return SmartException(
      message: 'Session expired. Please log in again.',
      type: SmartExceptionType.authRefreshFailed,
      rawError: cause,
    );
  }

  // ── Convenience Getters ──────────────────────────────────────────────────

  bool get isNetworkError =>
      type == SmartExceptionType.noInternet ||
      type == SmartExceptionType.timeout;

  bool get isAuthError =>
      type == SmartExceptionType.unauthorized ||
      type == SmartExceptionType.authRefreshFailed;

  bool get isRetryable =>
      type == SmartExceptionType.noInternet ||
      type == SmartExceptionType.timeout ||
      type == SmartExceptionType.serverError;

  // ── Private Helpers ──────────────────────────────────────────────────────

  static String _messageFromStatus(int? code, DioException e) {
    // First try to extract a message from the response body
    final body = e.response?.data;
    String? bodyMessage;
    if (body is Map) {
      bodyMessage = (body['message'] ?? body['error'] ?? body['detail'])
          ?.toString();
    }

    switch (code) {
      case 400:
        return bodyMessage ?? 'Bad request — please check your input.';
      case 401:
        return 'Unauthorized — please log in again.';
      case 403:
        return 'Forbidden — you do not have permission to access this.';
      case 404:
        return 'Resource not found (404).';
      case 409:
        return bodyMessage ?? 'Conflict — the resource already exists.';
      case 422:
        return bodyMessage ?? 'Validation error — check your request data.';
      case 429:
        return 'Too many requests — please slow down and try again later.';
      case 500:
        return 'Internal server error. The team has been notified.';
      case 502:
        return 'Bad gateway — the server is temporarily unavailable.';
      case 503:
        return 'Service unavailable — please try again shortly.';
      case 504:
        return 'Gateway timeout — the server took too long to respond.';
      default:
        return bodyMessage ??
            'Unexpected response from server (HTTP ${code ?? '?'}).';
    }
  }

  static SmartExceptionType _typeFromStatus(int? code) {
    if (code == null) return SmartExceptionType.unknown;
    switch (code) {
      case 401:
        return SmartExceptionType.unauthorized;
      case 403:
        return SmartExceptionType.forbidden;
      case 404:
        return SmartExceptionType.notFound;
      case 429:
        return SmartExceptionType.tooManyRequests;
      default:
        if (code >= 500) return SmartExceptionType.serverError;
        return SmartExceptionType.unknown;
    }
  }

  @override
  String toString() => 'SmartException[$type]'
      '${statusCode != null ? '(HTTP $statusCode)' : ''}'
      '${requestPath != null ? ' @ $requestPath' : ''}'
      ': $message'
      '${retryAttempts != null ? ' [after $retryAttempts retries]' : ''}';
}
