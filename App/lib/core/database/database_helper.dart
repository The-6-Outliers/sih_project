// lib/core/database/database_helper.dart
import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/inspection.dart';
import '../../models/inspection_media.dart';
import '../../models/sync_queue_item.dart';

/// Owns the single `sqflite` connection and every schema/CRUD concern.
///
/// The transactional heart of the engine is [saveInspectionWithSync]: it writes
/// the inspection, its media, and the outbox entry as one atomic unit.
class DatabaseHelper {
  DatabaseHelper._internal();

  static final DatabaseHelper instance = DatabaseHelper._internal();

  factory DatabaseHelper() => instance;

  static const String _dbName = 'coal_mine_inspector.db';
  static const int _dbVersion = 1;

  static const String tableInspections = 'inspections';
  static const String tableMedia = 'inspection_media';
  static const String tableSyncQueue = 'sync_queue';

  Database? _db;
  Future<Database>? _initFuture;

  /// Lazily opens the DB. Concurrent callers share the same in-flight open.
  Future<Database> get database async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;

    _initFuture ??= _initDatabase();
    try {
      final opened = await _initFuture!;
      _db = opened;
      return opened;
    } catch (_) {
      _initFuture = null; // allow a later retry
      rethrow;
    }
  }

  Future<Database> _initDatabase() async {
    final basePath = await getDatabasesPath();
    final fullPath = p.join(basePath, _dbName);
    return openDatabase(
      fullPath,
      version: _dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onConfigure(Database db) async {
    // Enforce FK constraints (inspection_media -> inspections ON DELETE CASCADE).
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE $tableInspections (
        id                 TEXT    PRIMARY KEY,
        server_id          TEXT,
        mine_code          TEXT    NOT NULL,
        inspector_id       TEXT    NOT NULL,
        inspection_type    TEXT    NOT NULL,
        title              TEXT    NOT NULL,
        notes              TEXT,
        severity           TEXT    NOT NULL DEFAULT 'low',
        latitude           REAL    NOT NULL,
        longitude          REAL    NOT NULL,
        accuracy           REAL    NOT NULL DEFAULT 0,
        altitude           REAL    NOT NULL DEFAULT 0,
        heading            REAL    NOT NULL DEFAULT 0,
        speed              REAL    NOT NULL DEFAULT 0,
        is_mocked          INTEGER NOT NULL DEFAULT 0,
        location_timestamp INTEGER,
        sync_status        TEXT    NOT NULL DEFAULT 'pending',
        created_at         INTEGER NOT NULL,
        updated_at         INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE $tableMedia (
        id              TEXT    PRIMARY KEY,
        inspection_id   TEXT    NOT NULL,
        local_path      TEXT    NOT NULL,
        file_name       TEXT    NOT NULL,
        media_type      TEXT    NOT NULL DEFAULT 'image',
        caption         TEXT,
        latitude        REAL,
        longitude       REAL,
        file_size_bytes INTEGER NOT NULL DEFAULT 0,
        captured_at     INTEGER NOT NULL,
        upload_status   TEXT    NOT NULL DEFAULT 'pending',
        remote_url      TEXT,
        created_at      INTEGER NOT NULL,
        FOREIGN KEY (inspection_id) REFERENCES $tableInspections (id) ON DELETE CASCADE
      )
    ''');

    batch.execute('''
      CREATE TABLE $tableSyncQueue (
        id              TEXT    PRIMARY KEY,
        entity_type     TEXT    NOT NULL,
        entity_id       TEXT    NOT NULL,
        operation       TEXT    NOT NULL DEFAULT 'create',
        payload         TEXT    NOT NULL,
        status          TEXT    NOT NULL DEFAULT 'pending',
        priority        INTEGER NOT NULL DEFAULT 0,
        retry_count     INTEGER NOT NULL DEFAULT 0,
        max_retries     INTEGER NOT NULL DEFAULT 5,
        last_attempt_at INTEGER,
        next_retry_at   INTEGER,
        last_error      TEXT,
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL
      )
    ''');

    batch.execute(
      'CREATE INDEX idx_media_inspection ON $tableMedia (inspection_id)',
    );
    batch.execute(
      'CREATE INDEX idx_media_upload_status ON $tableMedia (upload_status)',
    );
    batch.execute(
      'CREATE INDEX idx_sync_due ON $tableSyncQueue (status, priority, next_retry_at)',
    );
    batch.execute(
      'CREATE INDEX idx_sync_entity ON $tableSyncQueue (entity_type, entity_id)',
    );
    batch.execute(
      'CREATE INDEX idx_inspection_sync_status ON $tableInspections (sync_status)',
    );

    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Forward-only migrations. v1 is the baseline; add cases as the schema grows.
    for (var v = oldVersion + 1; v <= newVersion; v++) {
      switch (v) {
        // case 2:
        //   await db.execute('ALTER TABLE $tableInspections ADD COLUMN ...');
        //   break;
        default:
          break;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // TRANSACTIONAL OUTBOX WRITE
  // ---------------------------------------------------------------------------

  /// Atomically persists an [inspection], all of its [media] rows, and the
  /// [syncItem] outbox entry.
  ///
  /// All four writes commit together or not at all: any thrown error inside the
  /// `transaction` callback causes `sqflite` to `ROLLBACK`, leaving the DB
  /// exactly as it was before the call. This guarantees the outbox entry can
  /// never exist without its inspection, and an inspection captured offline can
  /// never exist without an outbox entry to sync it.
  Future<void> saveInspectionWithSync({
    required Inspection inspection,
    required List<InspectionMedia> media,
    required SyncQueueItem syncItem,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        tableInspections,
        inspection.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      for (final item in media) {
        assert(
          item.inspectionId == inspection.id,
          'media ${item.id} does not belong to inspection ${inspection.id}',
        );
        await txn.insert(
          tableMedia,
          item.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await txn.insert(
        tableSyncQueue,
        syncItem.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // INSPECTION READS / STATUS
  // ---------------------------------------------------------------------------

  Future<Inspection?> getInspectionById(String id) async {
    final db = await database;
    final rows = await db.query(
      tableInspections,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Inspection.fromMap(rows.first);
  }

  Future<List<Inspection>> getInspections({
    InspectionSyncStatus? syncStatus,
    int limit = 100,
    int offset = 0,
  }) async {
    final db = await database;
    final rows = await db.query(
      tableInspections,
      where: syncStatus == null ? null : 'sync_status = ?',
      whereArgs: syncStatus == null ? null : [syncStatus.name],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Inspection.fromMap).toList();
  }

  Future<int> updateInspectionSyncStatus(
    String id,
    InspectionSyncStatus status,
  ) async {
    final db = await database;
    return db.update(
      tableInspections,
      {
        'sync_status': status.name,
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> markInspectionSynced(String id, String? serverId) async {
    final db = await database;
    return db.update(
      tableInspections,
      {
        'sync_status': InspectionSyncStatus.synced.name,
        'server_id': serverId,
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------------------------------
  // MEDIA READS / STATUS
  // ---------------------------------------------------------------------------

  Future<List<InspectionMedia>> getMediaForInspection(String inspectionId) async {
    final db = await database;
    final rows = await db.query(
      tableMedia,
      where: 'inspection_id = ?',
      whereArgs: [inspectionId],
      orderBy: 'created_at ASC',
    );
    return rows.map(InspectionMedia.fromMap).toList();
  }

  Future<int> markMediaUploaded(String id, String? remoteUrl) async {
    final db = await database;
    return db.update(
      tableMedia,
      {
        'upload_status': MediaUploadStatus.uploaded.name,
        'remote_url': remoteUrl,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> updateMediaUploadStatus(String id, MediaUploadStatus status) async {
    final db = await database;
    return db.update(
      tableMedia,
      {'upload_status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------------------------------
  // SYNC QUEUE (OUTBOX) READS / WRITES
  // ---------------------------------------------------------------------------

  /// Items eligible for a sync pass: still pending or previously failed, and
  /// whose backoff window (`next_retry_at`) has elapsed. Highest priority and
  /// oldest first. `dead` items are intentionally excluded.
  Future<List<SyncQueueItem>> getDueSyncItems({int limit = 20}) async {
    final db = await database;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rows = await db.query(
      tableSyncQueue,
      where:
          "status IN ('pending', 'failed') AND (next_retry_at IS NULL OR next_retry_at <= ?)",
      whereArgs: [nowMs],
      orderBy: 'priority DESC, created_at ASC',
      limit: limit,
    );
    return rows.map(SyncQueueItem.fromMap).toList();
  }

  Future<List<SyncQueueItem>> getSyncItemsByStatus(SyncStatus status) async {
    final db = await database;
    final rows = await db.query(
      tableSyncQueue,
      where: 'status = ?',
      whereArgs: [status.name],
      orderBy: 'priority DESC, created_at ASC',
    );
    return rows.map(SyncQueueItem.fromMap).toList();
  }

  Future<int> countPendingSync() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM $tableSyncQueue WHERE status IN ('pending', 'failed', 'processing')",
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> updateSyncItem(SyncQueueItem item) async {
    final db = await database;
    final map = item.toMap();
    map['updated_at'] = DateTime.now().toUtc().millisecondsSinceEpoch;
    return db.update(
      tableSyncQueue,
      map,
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<int> deleteSyncItem(String id) async {
    final db = await database;
    return db.delete(tableSyncQueue, where: 'id = ?', whereArgs: [id]);
  }

  /// Re-arms a `dead` item for another round of attempts (manual recovery).
  Future<int> requeueSyncItem(String id) async {
    final db = await database;
    return db.update(
      tableSyncQueue,
      {
        'status': SyncStatus.pending.name,
        'retry_count': 0,
        'next_retry_at': null,
        'last_error': null,
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Recovers items stuck in `processing` after an abrupt process kill.
  Future<int> resetStaleProcessing({
    Duration olderThan = const Duration(minutes: 5),
  }) async {
    final db = await database;
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(olderThan)
        .millisecondsSinceEpoch;
    return db.update(
      tableSyncQueue,
      {
        'status': SyncStatus.pending.name,
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where:
          "status = 'processing' AND (last_attempt_at IS NULL OR last_attempt_at <= ?)",
      whereArgs: [cutoff],
    );
  }

  // ---------------------------------------------------------------------------
  // LIFECYCLE
  // ---------------------------------------------------------------------------

  Future<void> close() async {
    final db = _db;
    if (db != null && db.isOpen) {
      await db.close();
    }
    _db = null;
    _initFuture = null;
  }
}
