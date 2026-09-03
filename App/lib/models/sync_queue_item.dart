// lib/models/sync_queue_item.dart
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'inspection.dart';
import 'inspection_media.dart';

/// Sentinel to let [SyncQueueItem.copyWith] distinguish "keep existing value"
/// from "set to null" for nullable fields.
const Object _undefined = Object();

enum SyncOperation {
  create,
  update,
  delete;

  static SyncOperation fromName(String? value) {
    return SyncOperation.values.firstWhere(
      (e) => e.name == value,
      orElse: () => SyncOperation.create,
    );
  }
}

enum SyncStatus {
  /// Waiting to be picked up.
  pending,

  /// Currently being pushed by [SyncService] (in-flight lock at row level).
  processing,

  /// Last attempt failed; will retry once [nextRetryAt] elapses.
  failed,

  /// Retries exhausted. Terminal. Requires manual re-queue.
  dead,

  /// Successfully delivered. Rows are normally deleted, not left in this state.
  completed;

  static SyncStatus fromName(String? value) {
    return SyncStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => SyncStatus.pending,
    );
  }
}

/// One entry in the Transactional Outbox (`sync_queue` table).
///
/// Written **in the same transaction** as the domain rows it represents, so the
/// intent to sync can never be lost even if the process is killed immediately
/// after the local save.
class SyncQueueItem {
  static const String entityInspection = 'inspection';

  /// Client-generated UUID v4. Primary key.
  final String id;

  /// e.g. [entityInspection].
  final String entityType;

  /// The domain row's client UUID (e.g. `inspections.id`).
  final String entityId;

  final SyncOperation operation;

  /// Self-contained JSON snapshot of the payload at enqueue time (audit trail +
  /// replay safety even if the local row is later mutated).
  final String payload;

  final SyncStatus status;

  /// Higher runs first. Critical violations can jump the queue.
  final int priority;

  final int retryCount;
  final int maxRetries;

  final DateTime? lastAttemptAt;
  final DateTime? nextRetryAt;
  final String? lastError;

  final DateTime createdAt;
  final DateTime updatedAt;

  const SyncQueueItem({
    required this.id,
    required this.entityType,
    required this.entityId,
    this.operation = SyncOperation.create,
    required this.payload,
    this.status = SyncStatus.pending,
    this.priority = 0,
    this.retryCount = 0,
    this.maxRetries = 5,
    this.lastAttemptAt,
    this.nextRetryAt,
    this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get hasRetriesLeft => retryCount < maxRetries;

  bool isDue(DateTime now) =>
      nextRetryAt == null || !now.toUtc().isBefore(nextRetryAt!.toUtc());

  /// Builds an outbox entry for a freshly captured inspection + its media.
  factory SyncQueueItem.forInspection(
    Inspection inspection, {
    List<InspectionMedia> media = const [],
    SyncOperation operation = SyncOperation.create,
    int priority = 0,
    int maxRetries = 5,
    Uuid uuid = const Uuid(),
  }) {
    final now = DateTime.now().toUtc();
    final payload = jsonEncode({
      'operation': operation.name,
      'inspection': inspection.toJson(),
      'media': media.map((m) => m.toJson()).toList(),
    });
    return SyncQueueItem(
      id: uuid.v4(),
      entityType: entityInspection,
      entityId: inspection.id,
      operation: operation,
      payload: payload,
      status: SyncStatus.pending,
      priority: priority,
      retryCount: 0,
      maxRetries: maxRetries,
      createdAt: now,
      updatedAt: now,
    );
  }

  SyncQueueItem copyWith({
    String? id,
    String? entityType,
    String? entityId,
    SyncOperation? operation,
    String? payload,
    SyncStatus? status,
    int? priority,
    int? retryCount,
    int? maxRetries,
    Object? lastAttemptAt = _undefined,
    Object? nextRetryAt = _undefined,
    Object? lastError = _undefined,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SyncQueueItem(
      id: id ?? this.id,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      operation: operation ?? this.operation,
      payload: payload ?? this.payload,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      retryCount: retryCount ?? this.retryCount,
      maxRetries: maxRetries ?? this.maxRetries,
      lastAttemptAt: identical(lastAttemptAt, _undefined)
          ? this.lastAttemptAt
          : lastAttemptAt as DateTime?,
      nextRetryAt: identical(nextRetryAt, _undefined)
          ? this.nextRetryAt
          : nextRetryAt as DateTime?,
      lastError: identical(lastError, _undefined)
          ? this.lastError
          : lastError as String?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation.name,
      'payload': payload,
      'status': status.name,
      'priority': priority,
      'retry_count': retryCount,
      'max_retries': maxRetries,
      'last_attempt_at': lastAttemptAt?.toUtc().millisecondsSinceEpoch,
      'next_retry_at': nextRetryAt?.toUtc().millisecondsSinceEpoch,
      'last_error': lastError,
      'created_at': createdAt.toUtc().millisecondsSinceEpoch,
      'updated_at': updatedAt.toUtc().millisecondsSinceEpoch,
    };
  }

  factory SyncQueueItem.fromMap(Map<String, Object?> map) {
    DateTime? ts(Object? v) => v == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((v as num).toInt(), isUtc: true);
    return SyncQueueItem(
      id: map['id'] as String,
      entityType: map['entity_type'] as String,
      entityId: map['entity_id'] as String,
      operation: SyncOperation.fromName(map['operation'] as String?),
      payload: map['payload'] as String,
      status: SyncStatus.fromName(map['status'] as String?),
      priority: (map['priority'] as num? ?? 0).toInt(),
      retryCount: (map['retry_count'] as num? ?? 0).toInt(),
      maxRetries: (map['max_retries'] as num? ?? 5).toInt(),
      lastAttemptAt: ts(map['last_attempt_at']),
      nextRetryAt: ts(map['next_retry_at']),
      lastError: map['last_error'] as String?,
      createdAt: ts(map['created_at'])!,
      updatedAt: ts(map['updated_at'])!,
    );
  }

  Map<String, Object?> decodedPayload() =>
      jsonDecode(payload) as Map<String, Object?>;

  @override
  String toString() =>
      'SyncQueueItem(id: $id, $entityType/$entityId, ${operation.name}, '
      'status: ${status.name}, retries: $retryCount/$maxRetries)';
}
