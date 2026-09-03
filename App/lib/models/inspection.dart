// lib/models/inspection.dart
import 'dart:convert';

/// Local sync lifecycle for an [Inspection].
///
/// * [pending]   – created offline, waiting in the outbox.
/// * [processing]– currently being pushed by [SyncService].
/// * [synced]    – acknowledged by the server.
/// * [failed]    – retries exhausted; requires manual intervention.
enum InspectionSyncStatus {
  pending,
  processing,
  synced,
  failed;

  static InspectionSyncStatus fromName(String? value) {
    return InspectionSyncStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => InspectionSyncStatus.pending,
    );
  }
}

/// Severity classification for the observation / violation captured.
enum InspectionSeverity {
  low,
  medium,
  high,
  critical;

  static InspectionSeverity fromName(String? value) {
    return InspectionSeverity.values.firstWhere(
      (e) => e.name == value,
      orElse: () => InspectionSeverity.low,
    );
  }
}

/// A single field inspection / safety observation record.
///
/// Persisted in the `inspections` table. The primary key [id] is a
/// client-generated UUID v4 so the record is globally addressable the moment
/// it is created, with no round-trip to the server.
class Inspection {
  /// Client-generated UUID v4. Primary key. Never null, never server-assigned.
  final String id;

  /// Server-assigned identifier, populated after a successful sync.
  final String? serverId;

  final String mineCode;
  final String inspectorId;
  final String inspectionType;
  final String title;
  final String? notes;
  final InspectionSeverity severity;

  // --- Geo-tag (captured from LocationService at save time) ---
  final double latitude;
  final double longitude;
  final double accuracy;
  final double altitude;
  final double heading;
  final double speed;

  /// True when the OS reported the fix as mock / spoofed (`Position.isMocked`).
  final bool isMocked;

  /// Timestamp of the GNSS fix itself (distinct from [createdAt]).
  final DateTime? locationTimestamp;

  final InspectionSyncStatus syncStatus;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Inspection({
    required this.id,
    this.serverId,
    required this.mineCode,
    required this.inspectorId,
    required this.inspectionType,
    required this.title,
    this.notes,
    this.severity = InspectionSeverity.low,
    required this.latitude,
    required this.longitude,
    this.accuracy = 0,
    this.altitude = 0,
    this.heading = 0,
    this.speed = 0,
    this.isMocked = false,
    this.locationTimestamp,
    this.syncStatus = InspectionSyncStatus.pending,
    required this.createdAt,
    required this.updatedAt,
  });

  Inspection copyWith({
    String? id,
    String? serverId,
    String? mineCode,
    String? inspectorId,
    String? inspectionType,
    String? title,
    String? notes,
    InspectionSeverity? severity,
    double? latitude,
    double? longitude,
    double? accuracy,
    double? altitude,
    double? heading,
    double? speed,
    bool? isMocked,
    DateTime? locationTimestamp,
    InspectionSyncStatus? syncStatus,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Inspection(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      mineCode: mineCode ?? this.mineCode,
      inspectorId: inspectorId ?? this.inspectorId,
      inspectionType: inspectionType ?? this.inspectionType,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      severity: severity ?? this.severity,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      accuracy: accuracy ?? this.accuracy,
      altitude: altitude ?? this.altitude,
      heading: heading ?? this.heading,
      speed: speed ?? this.speed,
      isMocked: isMocked ?? this.isMocked,
      locationTimestamp: locationTimestamp ?? this.locationTimestamp,
      syncStatus: syncStatus ?? this.syncStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Row representation for `sqflite`. Booleans -> 0/1, `DateTime` -> epoch ms UTC.
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'server_id': serverId,
      'mine_code': mineCode,
      'inspector_id': inspectorId,
      'inspection_type': inspectionType,
      'title': title,
      'notes': notes,
      'severity': severity.name,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'altitude': altitude,
      'heading': heading,
      'speed': speed,
      'is_mocked': isMocked ? 1 : 0,
      'location_timestamp': locationTimestamp?.toUtc().millisecondsSinceEpoch,
      'sync_status': syncStatus.name,
      'created_at': createdAt.toUtc().millisecondsSinceEpoch,
      'updated_at': updatedAt.toUtc().millisecondsSinceEpoch,
    };
  }

  factory Inspection.fromMap(Map<String, Object?> map) {
    return Inspection(
      id: map['id'] as String,
      serverId: map['server_id'] as String?,
      mineCode: map['mine_code'] as String,
      inspectorId: map['inspector_id'] as String,
      inspectionType: map['inspection_type'] as String,
      title: map['title'] as String,
      notes: map['notes'] as String?,
      severity: InspectionSeverity.fromName(map['severity'] as String?),
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      accuracy: (map['accuracy'] as num? ?? 0).toDouble(),
      altitude: (map['altitude'] as num? ?? 0).toDouble(),
      heading: (map['heading'] as num? ?? 0).toDouble(),
      speed: (map['speed'] as num? ?? 0).toDouble(),
      isMocked: ((map['is_mocked'] as num?)?.toInt() ?? 0) == 1,
      locationTimestamp: map['location_timestamp'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (map['location_timestamp'] as num).toInt(),
              isUtc: true,
            ),
      syncStatus: InspectionSyncStatus.fromName(map['sync_status'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as num).toInt(),
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['updated_at'] as num).toInt(),
        isUtc: true,
      ),
    );
  }

  /// Wire format for the REST API (ISO-8601 timestamps, native booleans).
  Map<String, Object?> toJson() {
    return {
      'client_id': id,
      'server_id': serverId,
      'mine_code': mineCode,
      'inspector_id': inspectorId,
      'inspection_type': inspectionType,
      'title': title,
      'notes': notes,
      'severity': severity.name,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'altitude': altitude,
      'heading': heading,
      'speed': speed,
      'is_mocked': isMocked,
      'location_timestamp': locationTimestamp?.toUtc().toIso8601String(),
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  factory Inspection.fromJson(Map<String, Object?> json) {
    DateTime? parseTs(Object? v) =>
        v == null ? null : DateTime.parse(v as String).toUtc();
    return Inspection(
      id: (json['client_id'] ?? json['id']) as String,
      serverId: json['server_id'] as String?,
      mineCode: json['mine_code'] as String,
      inspectorId: json['inspector_id'] as String,
      inspectionType: json['inspection_type'] as String,
      title: json['title'] as String,
      notes: json['notes'] as String?,
      severity: InspectionSeverity.fromName(json['severity'] as String?),
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracy: (json['accuracy'] as num? ?? 0).toDouble(),
      altitude: (json['altitude'] as num? ?? 0).toDouble(),
      heading: (json['heading'] as num? ?? 0).toDouble(),
      speed: (json['speed'] as num? ?? 0).toDouble(),
      isMocked: json['is_mocked'] as bool? ?? false,
      locationTimestamp: parseTs(json['location_timestamp']),
      syncStatus: InspectionSyncStatus.fromName(json['sync_status'] as String?),
      createdAt: parseTs(json['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: parseTs(json['updated_at']) ?? DateTime.now().toUtc(),
    );
  }

  @override
  String toString() =>
      'Inspection(id: $id, mine: $mineCode, type: $inspectionType, '
      'sync: ${syncStatus.name}, mocked: $isMocked)';
}
