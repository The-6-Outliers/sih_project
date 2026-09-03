// lib/models/inspection_media.dart
import 'dart:convert';

enum MediaType {
  image,
  video,
  audio,
  document;

  static MediaType fromName(String? value) {
    return MediaType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MediaType.image,
    );
  }
}

enum MediaUploadStatus {
  pending,
  uploading,
  uploaded,
  failed;

  static MediaUploadStatus fromName(String? value) {
    return MediaUploadStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MediaUploadStatus.pending,
    );
  }
}

/// A single evidence file (photo/video/audio) attached to an [Inspection].
///
/// Persisted in `inspection_media`. [localPath] is always an **absolute** path
/// inside the app's documents directory, so it survives process death and app
/// restarts (unlike the OS cache path that `image_picker` hands back).
class InspectionMedia {
  /// Client-generated UUID v4. Primary key.
  final String id;

  /// FK -> `inspections.id`. `ON DELETE CASCADE`.
  final String inspectionId;

  final String localPath;
  final String fileName;
  final MediaType mediaType;
  final String? caption;

  // Geo-tag of the capture moment (may differ from the parent inspection fix).
  final double? latitude;
  final double? longitude;

  final int fileSizeBytes;
  final DateTime capturedAt;

  final MediaUploadStatus uploadStatus;
  final String? remoteUrl;

  final DateTime createdAt;

  const InspectionMedia({
    required this.id,
    required this.inspectionId,
    required this.localPath,
    required this.fileName,
    this.mediaType = MediaType.image,
    this.caption,
    this.latitude,
    this.longitude,
    this.fileSizeBytes = 0,
    required this.capturedAt,
    this.uploadStatus = MediaUploadStatus.pending,
    this.remoteUrl,
    required this.createdAt,
  });

  InspectionMedia copyWith({
    String? id,
    String? inspectionId,
    String? localPath,
    String? fileName,
    MediaType? mediaType,
    String? caption,
    double? latitude,
    double? longitude,
    int? fileSizeBytes,
    DateTime? capturedAt,
    MediaUploadStatus? uploadStatus,
    String? remoteUrl,
    DateTime? createdAt,
  }) {
    return InspectionMedia(
      id: id ?? this.id,
      inspectionId: inspectionId ?? this.inspectionId,
      localPath: localPath ?? this.localPath,
      fileName: fileName ?? this.fileName,
      mediaType: mediaType ?? this.mediaType,
      caption: caption ?? this.caption,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      capturedAt: capturedAt ?? this.capturedAt,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'inspection_id': inspectionId,
      'local_path': localPath,
      'file_name': fileName,
      'media_type': mediaType.name,
      'caption': caption,
      'latitude': latitude,
      'longitude': longitude,
      'file_size_bytes': fileSizeBytes,
      'captured_at': capturedAt.toUtc().millisecondsSinceEpoch,
      'upload_status': uploadStatus.name,
      'remote_url': remoteUrl,
      'created_at': createdAt.toUtc().millisecondsSinceEpoch,
    };
  }

  factory InspectionMedia.fromMap(Map<String, Object?> map) {
    return InspectionMedia(
      id: map['id'] as String,
      inspectionId: map['inspection_id'] as String,
      localPath: map['local_path'] as String,
      fileName: map['file_name'] as String,
      mediaType: MediaType.fromName(map['media_type'] as String?),
      caption: map['caption'] as String?,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      fileSizeBytes: (map['file_size_bytes'] as num? ?? 0).toInt(),
      capturedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['captured_at'] as num).toInt(),
        isUtc: true,
      ),
      uploadStatus: MediaUploadStatus.fromName(map['upload_status'] as String?),
      remoteUrl: map['remote_url'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as num).toInt(),
        isUtc: true,
      ),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'client_id': id,
      'inspection_client_id': inspectionId,
      'file_name': fileName,
      'media_type': mediaType.name,
      'caption': caption,
      'latitude': latitude,
      'longitude': longitude,
      'file_size_bytes': fileSizeBytes,
      'captured_at': capturedAt.toUtc().toIso8601String(),
      'remote_url': remoteUrl,
      'created_at': createdAt.toUtc().toIso8601String(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  factory InspectionMedia.fromJson(Map<String, Object?> json) {
    DateTime parseTs(Object? v) => v == null
        ? DateTime.now().toUtc()
        : DateTime.parse(v as String).toUtc();
    return InspectionMedia(
      id: (json['client_id'] ?? json['id']) as String,
      inspectionId:
          (json['inspection_client_id'] ?? json['inspection_id']) as String,
      localPath: json['local_path'] as String? ?? '',
      fileName: json['file_name'] as String,
      mediaType: MediaType.fromName(json['media_type'] as String?),
      caption: json['caption'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      fileSizeBytes: (json['file_size_bytes'] as num? ?? 0).toInt(),
      capturedAt: parseTs(json['captured_at']),
      uploadStatus: MediaUploadStatus.fromName(json['upload_status'] as String?),
      remoteUrl: json['remote_url'] as String?,
      createdAt: parseTs(json['created_at']),
    );
  }

  @override
  String toString() =>
      'InspectionMedia(id: $id, file: $fileName, ${fileSizeBytes}B, '
      'status: ${uploadStatus.name})';
}
