// lib/core/services/sync_service.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import '../../models/inspection.dart';
import '../../models/inspection_media.dart';
import '../../models/sync_queue_item.dart';
import '../database/database_helper.dart';

/// Static tuning for [SyncService].
class SyncConfig {
  final String baseUrl;

  /// Endpoint that accepts the multipart inspection bundle.
  final String inspectionsPath;

  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;

  /// Max outbox rows drained per pass.
  final int batchSize;

  /// Retry ceiling before a row is marked `dead`.
  final int maxRetries;

  /// Backoff base; effective delay = base * 2^(attempt-1) +/- 20% jitter.
  final Duration baseBackoff;

  /// Upper bound on any single backoff delay.
  final Duration maxBackoff;

  /// Periodic safety-net sweep interval (independent of connectivity events).
  final Duration periodicInterval;

  const SyncConfig({
    required this.baseUrl,
    this.inspectionsPath = '/api/v1/inspections/sync',
    this.connectTimeout = const Duration(seconds: 20),
    this.sendTimeout = const Duration(seconds: 60),
    this.receiveTimeout = const Duration(seconds: 30),
    this.batchSize = 15,
    this.maxRetries = 5,
    this.baseBackoff = const Duration(seconds: 15),
    this.maxBackoff = const Duration(minutes: 30),
    this.periodicInterval = const Duration(minutes: 15),
  });
}

/// Resolves the current bearer token (or `null` when unauthenticated).
typedef TokenProvider = FutureOr<String?> Function();

/// Outcome of one [SyncService.syncNow] pass.
class SyncResult {
  final int processed;
  final int succeeded;
  final int failed;
  final bool skipped;
  final String? reason;

  const SyncResult({
    this.processed = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.skipped = false,
    this.reason,
  });

  bool get hadWork => processed > 0;

  @override
  String toString() => skipped
      ? 'SyncResult(skipped: $reason)'
      : 'SyncResult(processed: $processed, ok: $succeeded, failed: $failed)';
}

/// Drains the Transactional Outbox (`sync_queue`) to the server.
///
/// * Reacts to `connectivity_plus` events (`List<ConnectivityResult>`).
/// * A single boolean lock ([_isSyncing]) guarantees only one pass runs at a
///   time; overlapping triggers are coalesced.
/// * Builds `multipart/form-data` with `dio`, streaming each media file.
/// * Per-row exponential backoff with jitter; a `max_retries` ceiling parks
///   poison rows as `dead`.
class SyncService {
  SyncService({
    required SyncConfig config,
    DatabaseHelper? database,
    Dio? dio,
    Connectivity? connectivity,
    TokenProvider? tokenProvider,
  })  : _config = config,
        _db = database ?? DatabaseHelper.instance,
        _connectivity = connectivity ?? Connectivity(),
        _tokenProvider = tokenProvider,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: config.baseUrl,
                connectTimeout: config.connectTimeout,
                sendTimeout: config.sendTimeout,
                receiveTimeout: config.receiveTimeout,
                responseType: ResponseType.json,
                validateStatus: (_) => true,
              ),
            );

  // ---------------------------------------------------------------------------
  // SINGLETON BOOTSTRAP
  // ---------------------------------------------------------------------------

  static SyncService? _instance;

  /// The process-wide instance created by [ensureInitialised] (call it in main).
  static SyncService get instance {
    final existing = _instance;
    if (existing == null) {
      throw StateError(
        'SyncService has not been initialised. Call '
        'SyncService.ensureInitialised(...) in main() before using it.',
      );
    }
    return existing;
  }

  static bool get isInitialised => _instance != null;

  /// Idempotent: returns the existing instance if one was already created.
  static SyncService ensureInitialised({
    required SyncConfig config,
    DatabaseHelper? database,
    Dio? dio,
    Connectivity? connectivity,
    TokenProvider? tokenProvider,
  }) {
    return _instance ??= SyncService(
      config: config,
      database: database,
      dio: dio,
      connectivity: connectivity,
      tokenProvider: tokenProvider,
    );
  }

  /// Test / hot-restart hook.
  static Future<void> resetInstance() async {
    await _instance?.dispose();
    _instance = null;
  }

  // ---------------------------------------------------------------------------

  final SyncConfig _config;
  final DatabaseHelper _db;
  final Dio _dio;
  final Connectivity _connectivity;
  final TokenProvider? _tokenProvider;

  final Random _random = Random();

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _periodicTimer;

  /// The concurrency lock. Only ever mutated on the main isolate.
  bool _isSyncing = false;

  bool _online = false;

  final StreamController<SyncResult> _resultController =
      StreamController<SyncResult>.broadcast();

  final StreamController<bool> _onlineController =
      StreamController<bool>.broadcast();

  /// Emits once per completed [syncNow] pass (including skipped passes).
  Stream<SyncResult> get onSyncComplete => _resultController.stream;

  /// Emits `true`/`false` whenever reachability flips. Seeded on [start].
  Stream<bool> get onOnlineStatusChanged => _onlineController.stream;

  bool get isSyncing => _isSyncing;

  bool get isOnline => _online;

  // ---------------------------------------------------------------------------
  // LIFECYCLE
  // ---------------------------------------------------------------------------

  /// Wires up connectivity + periodic triggers and kicks an initial pass.
  Future<void> start() async {
    // Recover any rows left mid-flight by a previous process kill.
    await _db.resetStaleProcessing();

    final initial = await _connectivity.checkConnectivity();
    _online = _hasConnection(initial);
    _emitOnline();

    await _connSub?.cancel();
    _connSub =
        _connectivity.onConnectivityChanged.listen(_handleConnectivityChange);

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(
      _config.periodicInterval,
      (_) => unawaited(syncNow()),
    );

    if (_online) {
      unawaited(syncNow());
    }
  }

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final wasOnline = _online;
    _online = _hasConnection(results);
    if (wasOnline != _online) _emitOnline();

    // Rising edge offline -> online: drain immediately.
    if (!wasOnline && _online) {
      unawaited(syncNow());
    }
  }

  bool _hasConnection(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return results.any((r) => r != ConnectivityResult.none);
  }

  void _emitOnline() {
    if (!_onlineController.isClosed) _onlineController.add(_online);
  }

  // ---------------------------------------------------------------------------
  // SYNC PASS
  // ---------------------------------------------------------------------------

  /// UI-facing alias. Drains the outbox once; callers typically do not await it.
  Future<SyncResult> syncPendingItems() => syncNow();

  /// Public manual trigger (e.g. pull-to-refresh).
  Future<SyncResult> triggerSync() => syncNow();

  /// Runs a single drain pass. Safe to call from anywhere; concurrent calls
  /// return a `skipped` result instead of starting a second pass.
  Future<SyncResult> syncNow() async {
    if (_isSyncing) {
      const r = SyncResult(skipped: true, reason: 'already-running');
      _resultController.add(r);
      return r;
    }

    _isSyncing = true;
    var processed = 0;
    var succeeded = 0;
    var failed = 0;

    try {
      final connectivity = await _connectivity.checkConnectivity();
      final wasOnline = _online;
      _online = _hasConnection(connectivity);
      if (wasOnline != _online) _emitOnline();

      if (!_online) {
        const r = SyncResult(skipped: true, reason: 'offline');
        _resultController.add(r);
        return r;
      }

      final items = await _db.getDueSyncItems(limit: _config.batchSize);
      for (final item in items) {
        processed++;
        final ok = await _processItem(item);
        if (ok) {
          succeeded++;
        } else {
          failed++;
        }
      }
    } catch (e) {
      final r = SyncResult(
        processed: processed,
        succeeded: succeeded,
        failed: failed,
        reason: 'pass-error: $e',
      );
      _resultController.add(r);
      return r;
    } finally {
      _isSyncing = false;
    }

    final result = SyncResult(
      processed: processed,
      succeeded: succeeded,
      failed: failed,
    );
    _resultController.add(result);
    return result;
  }

  // ---------------------------------------------------------------------------
  // PER-ROW PROCESSING
  // ---------------------------------------------------------------------------

  Future<bool> _processItem(SyncQueueItem item) async {
    final now = DateTime.now().toUtc();

    await _db.updateSyncItem(
      item.copyWith(
        status: SyncStatus.processing,
        lastAttemptAt: now,
        updatedAt: now,
      ),
    );
    await _db.updateInspectionSyncStatus(
      item.entityId,
      InspectionSyncStatus.processing,
    );

    try {
      switch (item.entityType) {
        case SyncQueueItem.entityInspection:
          await _pushInspection(item);
          break;
        default:
          throw _FatalSyncError('Unsupported entity type: ${item.entityType}');
      }

      await _db.markInspectionSynced(item.entityId, _lastServerId);
      await _db.deleteSyncItem(item.id);
      return true;
    } on _FatalSyncError catch (e) {
      await _fail(item, error: e.message, fatal: true);
      return false;
    } catch (e) {
      await _fail(item, error: e.toString(), fatal: false);
      return false;
    } finally {
      _lastServerId = null;
    }
  }

  Future<void> _fail(
    SyncQueueItem item, {
    required String error,
    required bool fatal,
  }) async {
    final now = DateTime.now().toUtc();
    final attempt = item.retryCount + 1;
    final exhausted = fatal || attempt >= item.maxRetries;

    await _db.updateSyncItem(
      item.copyWith(
        status: exhausted ? SyncStatus.dead : SyncStatus.failed,
        retryCount: attempt,
        lastAttemptAt: now,
        nextRetryAt: exhausted ? null : now.add(_backoffFor(attempt)),
        lastError: error,
        updatedAt: now,
      ),
    );

    await _db.updateInspectionSyncStatus(
      item.entityId,
      exhausted ? InspectionSyncStatus.failed : InspectionSyncStatus.pending,
    );
  }

  String? _lastServerId;

  Future<void> _pushInspection(SyncQueueItem item) async {
    final inspection = await _db.getInspectionById(item.entityId);
    if (inspection == null) {
      return; // local row gone; nothing to send
    }

    final media = await _db.getMediaForInspection(item.entityId);

    final formMap = <String, dynamic>{
      'operation': item.operation.name,
      'client_id': inspection.id,
      'payload': item.payload,
    };
    inspection.toJson().forEach((key, value) {
      if (value == null) return;
      formMap[key] = value is bool ? value.toString() : value;
    });

    final fileEntries = <MapEntry<String, MultipartFile>>[];

    for (final m in media) {
      if (m.uploadStatus == MediaUploadStatus.uploaded) {
        formMap['media_meta[${m.id}]'] = m.toJsonString();
        continue;
      }
      final file = File(m.localPath);
      if (!await file.exists()) {
        await _db.updateMediaUploadStatus(m.id, MediaUploadStatus.failed);
        continue;
      }
      await _db.updateMediaUploadStatus(m.id, MediaUploadStatus.uploading);
      fileEntries.add(
        MapEntry(
          'media[]',
          await MultipartFile.fromFile(
            file.path,
            filename: m.fileName,
            contentType: DioMediaType.parse(_mimeFor(m.fileName)),
          ),
        ),
      );
      formMap['media_meta[${m.id}]'] = m.toJsonString();
    }

    final formData = FormData.fromMap(formMap);
    formData.files.addAll(fileEntries);

    final token = await _resolveToken();

    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        _config.inspectionsPath,
        data: formData,
        options: Options(
          contentType: 'multipart/form-data',
          headers: {
            'Accept': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ),
      );
    } on DioException catch (e) {
      throw 'Network error (${e.type.name}): ${e.message}';
    }

    final status = response.statusCode ?? 0;

    if (status == 401 || status == 403) {
      throw 'Authentication rejected (HTTP $status).';
    }
    if (status == 409 || status == 422) {
      throw _FatalSyncError(
        'Server rejected inspection (HTTP $status): ${_briefBody(response.data)}',
      );
    }
    if (status < 200 || status >= 300) {
      throw 'Server returned HTTP $status: ${_briefBody(response.data)}';
    }

    _absorbSuccessBody(inspection, media, response.data);
  }

  void _absorbSuccessBody(
    Inspection inspection,
    List<InspectionMedia> media,
    dynamic body,
  ) {
    if (body is! Map) {
      _lastServerId = null;
      return;
    }

    final serverId = body['server_id'] ?? body['id'];
    _lastServerId = serverId?.toString();

    final mediaResp = body['media'];
    if (mediaResp is List) {
      for (final entry in mediaResp) {
        if (entry is! Map) continue;
        final clientId = (entry['client_id'] ?? entry['id'])?.toString();
        final remoteUrl = (entry['remote_url'] ?? entry['url'])?.toString();
        if (clientId != null) {
          unawaited(_db.markMediaUploaded(clientId, remoteUrl));
        }
      }
    } else {
      for (final m in media) {
        unawaited(_db.markMediaUploaded(m.id, null));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  Duration _backoffFor(int attempt) {
    final baseMs = _config.baseBackoff.inMilliseconds;
    final maxMs = _config.maxBackoff.inMilliseconds;

    final shift = (attempt - 1).clamp(0, 30);
    final rawMs = baseMs * (1 << shift);
    final cappedMs = rawMs > maxMs ? maxMs : rawMs;

    final jitterBand = (cappedMs * 0.2).round();
    final delta =
        jitterBand == 0 ? 0 : _random.nextInt(jitterBand * 2 + 1) - jitterBand;

    final finalMs = (cappedMs + delta).clamp(baseMs, maxMs);
    return Duration(milliseconds: finalMs);
  }

  Future<String?> _resolveToken() async {
    final provider = _tokenProvider;
    if (provider == null) return null;
    return provider();
  }

  String _mimeFor(String fileName) {
    final ext = fileName.toLowerCase().split('.').last;
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'm4a':
      case 'aac':
        return 'audio/aac';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }

  String _briefBody(dynamic body) {
    final text = body?.toString() ?? '';
    return text.length <= 300 ? text : '${text.substring(0, 300)}...';
  }

  Future<void> dispose() async {
    await _connSub?.cancel();
    _connSub = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _dio.close(force: true);
    await _resultController.close();
    await _onlineController.close();
  }
}

/// Marks a failure that must NOT be retried (bad request, unsupported type).
class _FatalSyncError implements Exception {
  final String message;
  const _FatalSyncError(this.message);
  @override
  String toString() => 'FatalSyncError: $message';
}
