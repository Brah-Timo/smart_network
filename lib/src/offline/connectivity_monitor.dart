import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Monitors device connectivity and notifies listeners when the network
/// status changes.
///
/// Uses `connectivity_plus` to listen to platform events. On reconnect,
/// the [onConnected] callback is invoked so [QueueProcessor] can replay
/// the offline queue.
///
/// ### Usage
/// ```dart
/// final monitor = ConnectivityMonitor();
/// monitor.startMonitoring(onConnected: () => queue.processQueue(dio));
///
/// // Later:
/// monitor.stopMonitoring();
/// ```
class ConnectivityMonitor {
  final Connectivity _connectivity;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _wasOffline = false;
  bool _isMonitoring = false;

  ConnectivityMonitor({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  /// True when a network interface is available.
  ///
  /// Note: `true` means a network interface exists — it does NOT
  /// guarantee internet reachability (captive portals, firewalls, etc.).
  Future<bool> get isConnected async {
    final results = await _connectivity.checkConnectivity();
    return _hasConnection(results);
  }

  /// Starts listening for connectivity changes.
  ///
  /// [onConnected] is invoked when the device transitions from offline to
  /// online.
  ///
  /// [onDisconnected] is invoked when the device goes offline.
  void startMonitoring({
    required void Function() onConnected,
    void Function()? onDisconnected,
  }) {
    if (_isMonitoring) return;
    _isMonitoring = true;

    // Establish initial state
    _connectivity.checkConnectivity().then((results) {
      _wasOffline = !_hasConnection(results);
    });

    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        final nowConnected = _hasConnection(results);

        if (nowConnected && _wasOffline) {
          // Transitioned: offline → online
          onConnected();
        } else if (!nowConnected && !_wasOffline) {
          // Transitioned: online → offline
          onDisconnected?.call();
        }

        _wasOffline = !nowConnected;
      },
    );
  }

  /// Cancels the connectivity subscription.
  void stopMonitoring() {
    _subscription?.cancel();
    _subscription = null;
    _isMonitoring = false;
  }

  bool get isMonitoring => _isMonitoring;

  static bool _hasConnection(List<ConnectivityResult> results) {
    return results.any(
      (r) =>
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn,
    );
  }

  @override
  String toString() =>
      'ConnectivityMonitor(monitoring: $_isMonitoring, wasOffline: $_wasOffline)';
}
