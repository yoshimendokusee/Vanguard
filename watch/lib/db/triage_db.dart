import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

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
  /// hub uses to drop duplicate syncs.
  final String createdAt;
  final bool synced;
}

/// Offline triage queue. Every report lands here first, whether or not any
/// hospital is reachable.
class TriageDb {
  TriageDb._(this._db, this.watchId);

  final Database _db;
  final String watchId;
  int _lastTs = 0;

  static Future<TriageDb> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'vanguard.db'),
      version: 1,
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
            sync_status INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute(
          'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      },
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

  Future<TriageRow> insert(TriageResult r) async {
    // Keep timestamps strictly increasing so (watch_id, created_at) stays
    // unique even if two reports land in the same millisecond.
    var ts = DateTime.now().millisecondsSinceEpoch;
    if (ts <= _lastTs) ts = _lastTs + 1;
    _lastTs = ts;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      ts,
      isUtc: true,
    ).toIso8601String();

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

  Future<void> markSynced(Iterable<int> ids) async {
    if (ids.isEmpty) return;
    final marks = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE triage_logs SET sync_status = 1 WHERE id IN ($marks)',
      ids.toList(),
    );
  }
}
