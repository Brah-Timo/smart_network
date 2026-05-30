import 'dart:async';
import 'package:dio/dio.dart';

/// Holds the [Completer] for an in-flight request so that subsequent
/// identical requests can share the same [Future] outcome.
///
/// Created by [RequestDeduplicator.addPending] when the first request
/// with a given key is dispatched, and completed (or errored) by
/// [RequestDeduplicator.complete] / [RequestDeduplicator.completeError]
/// when Dio finishes the request.
class PendingRequest {
  /// Resolves (or rejects) with the same [Response] for all waiters.
  final Completer<Response<dynamic>> completer;

  /// The wall-clock time when this pending request was created.
  final DateTime createdAt;

  PendingRequest({required this.completer})
      : createdAt = DateTime.now();

  /// How long this request has been waiting.
  Duration get age => DateTime.now().difference(createdAt);

  bool get isCompleted => completer.isCompleted;

  @override
  String toString() =>
      'PendingRequest(age: ${age.inMilliseconds}ms, done: $isCompleted)';
}
