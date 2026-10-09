import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../nlp/triage_parser.dart';

class TriageRow {
  const TriageRow({
    required this.id,
    required this.location,
    required this.injuries,
    required this.triage,
    required this.patientCount,
    required this.ageGroup,
    required this.etaMinutes,
    required this.rawText,
    required this.createdAt,
    required this.synced,
    required this.reportId,
    required this.cloudOwnerId,
    required this.cloudSynced,
  });

  factory TriageRow.fromMap(Map<String, Object?> m) => TriageRow(
    id: m['id'] as int,
    location: m['location'] as String,
    injuries: m['injuries'] as String,
    triage: m['triage'] as String,
    patientCount: m['patient_count'] as int,
    ageGroup: m['age_group'] as String,
    etaMinutes: m['eta_minutes'] as int?,
    rawText: m['raw_text'] as String,
    createdAt: m['created_at'] as String,
    synced: (m['sync_status'] as int) == 1,
    reportId: m['report_id'] as String,
    cloudOwnerId: m['cloud_owner_id'] as String?,
    cloudSynced: (m['cloud_sync_status'] as int) == 1,
  );

  final int id;
  final String location;
  final String injuries;
  final String triage;
  final int patientCount;
  final String ageGroup;
  final int? etaMinutes;
  final String rawText;

  /// ISO-8601 UTC. Together with the watch ID this is the idempotency key the
  /// hub uses for legacy LAN deduplication. Supabase uses [reportId].
  final String createdAt;
  final bool synced;
  final String reportId;
  final String? cloudOwnerId;
  final bool cloudSynced;
}

/// Offline triage queue. Every report lands here first, whether or not any
/// hospital is reachable.
class TriageDb {
  TriageDb._(this._db, this.watchId);

  static final _uuid = Uuid();

  final Database _db;
  final String watchId;
  int _lastTs = 0;

  static Future<TriageDb> open({DatabaseFactory? factory, String? path}) async {
    final dbFactory = factory ?? databaseFactory;
    final databasePath =
        path ?? p.join(await getDatabasesPath(), 'vanguard.db');
    final db = await dbFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE triage_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              location TEXT NOT NULL,
              injuries TEXT NOT NULL,
              triage TEXT NOT NULL,
              patient_count INTEGER NOT NULL DEFAULT 1,
              age_group TEXT NOT NULL,
              eta_minutes INTEGER,
              raw_text TEXT NOT NULL,
              created_at TEXT NOT NULL,
              sync_status INTEGER NOT NULL DEFAULT 0,
              report_id TEXT NOT NULL UNIQUE,
              cloud_owner_id TEXT,
              cloud_sync_status INTEGER NOT NULL DEFAULT 0
            )''');
          await db.execute(
            'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE triage_logs ADD COLUMN report_id TEXT',
            );
            await db.execute(
              'ALTER TABLE triage_logs ADD COLUMN cloud_owner_id TEXT',
            );
            await db.execute(
              'ALTER TABLE triage_logs ADD COLUMN cloud_sync_status INTEGER NOT NULL DEFAULT 0',
            );
            final rows = await db.query('triage_logs', columns: ['id']);
            for (final row in rows) {
              await db.update(
                'triage_logs',
                {'report_id': _uuid.v4()},
                where: 'id = ?',
                whereArgs: [row['id']],
              );
            }
            await db.execute(
              'CREATE UNIQUE INDEX triage_logs_report_id ON triage_logs(report_id)',
            );
          }
        },
      ),
    );

    final rows = await db.query('meta', where: "key = 'watch_id'");
    String watchId;
    if (rows.isEmpty) {
      final rnd = Random.secure();
      watchId =
          'W-${List.generate(4, (_) => rnd.nextInt(16).toRadixString(16)).join().toUpperCase()}';
      await db.insert('meta', {'key': 'watch_id', 'value': watchId});
    } else {
      watchId = rows.first['value'] as String;
    }
    return TriageDb._(db, watchId);
  }

  Future<void> close() => _db.close();

  Future<TriageRow> insert(TriageResult r, {String? cloudOwnerId}) async {
    // Keep timestamps strictly increasing so (watch_id, created_at) stays
    // unique even if two reports land in the same millisecond.
    var ts = DateTime.now().millisecondsSinceEpoch;
    if (ts <= _lastTs) ts = _lastTs + 1;
    _lastTs = ts;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      ts,
      isUtc: true,
    ).toIso8601String();
    final reportId = _uuid.v4();

    final id = await _db.insert('triage_logs', {
      'location': r.location,
      'injuries': r.injuriesText,
      'triage': r.triage,
      'patient_count': r.patientCount,
      'age_group': r.ageGroup,
      'eta_minutes': r.etaMinutes,
      'raw_text': r.rawText,
      'created_at': createdAt,
      'sync_status': 0,
      'report_id': reportId,
      'cloud_owner_id': cloudOwnerId,
      'cloud_sync_status': 0,
    });
    return TriageRow(
      id: id,
      location: r.location,
      injuries: r.injuriesText,
      triage: r.triage,
      patientCount: r.patientCount,
      ageGroup: r.ageGroup,
      etaMinutes: r.etaMinutes,
      rawText: r.rawText,
      createdAt: createdAt,
      synced: false,
      reportId: reportId,
      cloudOwnerId: cloudOwnerId,
      cloudSynced: false,
    );
  }

  Future<List<TriageRow>> pending() async => (await _db.query(
    'triage_logs',
    where: 'sync_status = 0',
    orderBy: 'id ASC',
  )).map(TriageRow.fromMap).toList();

  Future<int> pendingCount() async =>
      Sqflite.firstIntValue(
        await _db.rawQuery(
          'SELECT COUNT(*) FROM triage_logs WHERE sync_status = 0',
        ),
      ) ??
      0;

  Future<List<TriageRow>> pendingCloud(String userId) async => (await _db.query(
    'triage_logs',
    where: 'cloud_sync_status = 0 AND cloud_owner_id = ?',
    whereArgs: [userId],
    orderBy: 'id ASC',
  )).map(TriageRow.fromMap).toList();

  Future<int> pendingCloudCount({String? userId}) async {
    final rows = await _db.rawQuery(
      userId == null
          ? 'SELECT COUNT(*) FROM triage_logs WHERE cloud_sync_status = 0'
          : 'SELECT COUNT(*) FROM triage_logs WHERE cloud_sync_status = 0 AND cloud_owner_id = ?',
      userId == null ? null : [userId],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<int> unassignedCloudCount() async =>
      Sqflite.firstIntValue(
        await _db.rawQuery(
          'SELECT COUNT(*) FROM triage_logs '
          'WHERE cloud_sync_status = 0 AND cloud_owner_id IS NULL',
        ),
      ) ??
      0;

  Future<int> claimUnassignedCloudRows(String userId) => _db.rawUpdate(
    'UPDATE triage_logs SET cloud_owner_id = ? '
    'WHERE cloud_sync_status = 0 AND cloud_owner_id IS NULL',
    [userId],
  );

  Future<void> markCloudSynced(
    Iterable<String> reportIds, {
    required String userId,
  }) async {
    final ids = reportIds.toList();
    if (ids.isEmpty) return;
    final marks = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE triage_logs SET cloud_sync_status = 1 '
      'WHERE cloud_owner_id = ? AND report_id IN ($marks)',
      [userId, ...ids],
    );
  }

  Future<void> markSynced(Iterable<int> ids) async {
    if (ids.isEmpty) return;
    final marks = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE triage_logs SET sync_status = 1 WHERE id IN ($marks)',
      ids.toList(),
    );
  }
}
