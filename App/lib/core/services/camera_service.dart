// lib/core/services/camera_service.dart
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/inspection_media.dart';

/// Captures evidence photos and copies the raw bytes out of the OS cache into
/// the app's **persistent** documents directory, returning an [InspectionMedia]
/// whose `localPath` is an absolute, durable path.
class CameraService {
  CameraService({ImagePicker? picker, Uuid? uuid})
      : _picker = picker ?? ImagePicker(),
        _uuid = uuid ?? const Uuid();

  final ImagePicker _picker;
  final Uuid _uuid;

  /// Sub-folder under the app documents directory. Media is further namespaced
  /// per inspection: `<docs>/inspection_media/<inspectionId>/<mediaId>.jpg`.
  static const String mediaFolder = 'inspection_media';

  Future<Directory> _mediaDirFor(String inspectionId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, mediaFolder, inspectionId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Opens the system camera. Returns `null` if the user cancels.
  Future<InspectionMedia?> captureFromCamera({
    required String inspectionId,
    double? latitude,
    double? longitude,
    String? caption,
    int imageQuality = 88,
    double maxWidth = 2560,
    double maxHeight = 2560,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
  }) async {
    final XFile? shot = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: imageQuality,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      preferredCameraDevice: preferredCameraDevice,
      requestFullMetadata: true,
    );
    if (shot == null) return null;

    return _persist(
      inspectionId: inspectionId,
      source: shot,
      latitude: latitude,
      longitude: longitude,
      caption: caption,
    );
  }

  /// Picks an existing image from the gallery. Returns `null` if cancelled.
  Future<InspectionMedia?> pickFromGallery({
    required String inspectionId,
    double? latitude,
    double? longitude,
    String? caption,
    int imageQuality = 88,
    double maxWidth = 2560,
    double maxHeight = 2560,
  }) async {
    final XFile? picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: imageQuality,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      requestFullMetadata: true,
    );
    if (picked == null) return null;

    return _persist(
      inspectionId: inspectionId,
      source: picked,
      latitude: latitude,
      longitude: longitude,
      caption: caption,
    );
  }

  /// Picks multiple gallery images at once. Empty list if cancelled.
  Future<List<InspectionMedia>> pickMultipleFromGallery({
    required String inspectionId,
    double? latitude,
    double? longitude,
    int imageQuality = 88,
    double maxWidth = 2560,
    double maxHeight = 2560,
  }) async {
    final List<XFile> picked = await _picker.pickMultiImage(
      imageQuality: imageQuality,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      requestFullMetadata: true,
    );
    if (picked.isEmpty) return const [];

    final results = <InspectionMedia>[];
    for (final file in picked) {
      results.add(
        await _persist(
          inspectionId: inspectionId,
          source: file,
          latitude: latitude,
          longitude: longitude,
          caption: null,
        ),
      );
    }
    return results;
  }

  /// Copies [source] into persistent storage and builds the model.
  Future<InspectionMedia> _persist({
    required String inspectionId,
    required XFile source,
    required double? latitude,
    required double? longitude,
    required String? caption,
  }) async {
    final dir = await _mediaDirFor(inspectionId);

    final rawExt = p.extension(source.path);
    final ext = rawExt.isNotEmpty ? rawExt.toLowerCase() : '.jpg';

    final mediaId = _uuid.v4();
    final fileName = '$mediaId$ext';
    final destPath = p.join(dir.path, fileName);

    // Read the raw bytes and write them to our own directory. We do NOT rely on
    // XFile.saveTo / File.copy alone because some pickers return a content URI
    // whose backing file is reclaimable; readAsBytes forces a full materialise.
    final bytes = await source.readAsBytes();
    final destFile = File(destPath);
    await destFile.writeAsBytes(bytes, flush: true);

    final int sizeBytes = await destFile.length();
    final DateTime capturedAt = await _sourceTimestamp(source);
    final DateTime now = DateTime.now().toUtc();

    return InspectionMedia(
      id: mediaId,
      inspectionId: inspectionId,
      localPath: destFile.absolute.path,
      fileName: fileName,
      mediaType: MediaType.image,
      caption: caption,
      latitude: latitude,
      longitude: longitude,
      fileSizeBytes: sizeBytes,
      capturedAt: capturedAt,
      uploadStatus: MediaUploadStatus.pending,
      createdAt: now,
    );
  }

  Future<DateTime> _sourceTimestamp(XFile source) async {
    try {
      final lastModified = await source.lastModified();
      return lastModified.toUtc();
    } catch (_) {
      return DateTime.now().toUtc();
    }
  }

  /// Deletes the on-disk file for a media row (e.g. after successful upload,
  /// or when the user removes an attachment before sync).
  Future<void> deleteLocalFile(InspectionMedia media) async {
    final file = File(media.localPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Removes the whole media folder for an inspection (post-sync cleanup).
  Future<void> purgeInspectionMedia(String inspectionId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, mediaFolder, inspectionId));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
