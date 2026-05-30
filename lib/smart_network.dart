/// smart_network
///
/// A smart, production-ready networking layer for Flutter.
///
/// Features:
/// - 🔁 Automatic Retry with Exponential / Linear / Constant Backoff
/// - 🗄️ Multi-Strategy Cache (Memory + Hive): Cache-First, Network-First,
///       Network-Only, Cache-Only, Stale-While-Revalidate
/// - 🔀 Request Deduplication — prevents duplicate in-flight requests
/// - 📵 Offline Queue — persists requests on disk, auto-retries on reconnect
/// - 🔐 Thread-safe JWT Auto Refresh using Lock + Completer pattern
/// - 📦 Request Batching — groups multiple calls into one HTTP request
/// - 🪵 Built-in structured logging
///
/// Usage:
/// ```dart
/// import 'package:smart_network/smart_network.dart';
///
/// await SmartNetworkClient().initialize(SmartConfig(baseUrl: 'https://api.example.com'));
/// final response = await SmartNetworkClient().get<User>('/users/1', fromJson: User.fromJson);
/// ```
library smart_network;

// ── Core ──────────────────────────────────────────────────────────────────────
export 'src/core/smart_network_client.dart';
export 'src/core/smart_request.dart';
export 'src/core/smart_response.dart';
export 'src/core/smart_exception.dart';
export 'src/core/smart_config.dart';

// ── Cache ─────────────────────────────────────────────────────────────────────
export 'src/cache/smart_cache.dart';
export 'src/cache/memory_cache.dart';
export 'src/cache/hive_cache.dart';
export 'src/cache/cache_entry.dart';
export 'src/cache/cache_policy.dart';
export 'src/cache/cache_key_builder.dart';

// ── Retry ─────────────────────────────────────────────────────────────────────
export 'src/retry/retry_policy.dart';
export 'src/retry/retry_evaluator.dart';
export 'src/retry/backoff_strategy.dart';

// ── Deduplication ─────────────────────────────────────────────────────────────
export 'src/deduplication/request_deduplicator.dart';
export 'src/deduplication/pending_request.dart';

// ── Offline ───────────────────────────────────────────────────────────────────
export 'src/offline/offline_queue.dart';
export 'src/offline/offline_entry.dart';
export 'src/offline/connectivity_monitor.dart';
export 'src/offline/queue_processor.dart';

// ── Auth ──────────────────────────────────────────────────────────────────────
export 'src/auth/token_manager.dart';
export 'src/auth/token_storage.dart';
export 'src/auth/token_refresher.dart';

// ── Batch ─────────────────────────────────────────────────────────────────────
export 'src/batch/batch_config.dart';
export 'src/batch/batch_entry.dart';
export 'src/batch/batch_processor.dart';

// ── Utils ─────────────────────────────────────────────────────────────────────
export 'src/utils/logger.dart';
export 'src/utils/network_utils.dart';
