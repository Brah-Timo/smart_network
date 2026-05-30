import 'package:logger/logger.dart';

/// Structured logger for SmartNetwork.
///
/// All log messages are prefixed with `[SmartNetwork]` and routed
/// through the `logger` package for consistent formatting.
///
/// Set [enabled] to `false` (via [SmartConfig.enableLogging]) to silence
/// all output in production builds.
class SmartLogger {
  final bool enabled;
  final Logger _logger;

  SmartLogger({this.enabled = true})
      : _logger = Logger(
          printer: PrettyPrinter(
            methodCount: 0,
            errorMethodCount: 8,
            lineLength: 100,
            colors: true,
            printEmojis: true,
            dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
          ),
          level: enabled ? Level.trace : Level.off,
          filter: ProductionFilter(),
        );

  void t(String message) {
    if (!enabled) return;
    _logger.t('[SmartNetwork] $message');
  }

  void d(String message) {
    if (!enabled) return;
    _logger.d('[SmartNetwork] $message');
  }

  void i(String message) {
    if (!enabled) return;
    _logger.i('[SmartNetwork] $message');
  }

  void w(String message) {
    if (!enabled) return;
    _logger.w('[SmartNetwork] $message');
  }

  void e(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!enabled) return;
    _logger.e('[SmartNetwork] $message', error: error, stackTrace: stackTrace);
  }

  void f(String message, {Object? error, StackTrace? stackTrace}) {
    if (!enabled) return;
    _logger.f('[SmartNetwork] $message', error: error, stackTrace: stackTrace);
  }
}
