import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vanguard_wrist/db/triage_db.dart';
import 'package:vanguard_wrist/nlp/triage_parser.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'upgrades populated v1 queue without losing rows or sync state',
    () async {
      final directory = await Directory.systemTemp.createTemp('vanguard-db-');
      TriageDb? upgraded;
      TriageDb? reopened;
      addTearDown(() async {
        if (reopened != null) await reopened.close();
        if (upgraded != null) await upgraded.close();
        await directory.delete(recursive: true);
      });
      final databasePath = p.join(directory.path, 'vanguard.db');
      await _createVersionOneDatabase(databasePath);

      final upgradedDb = await TriageDb.open(
        factory: databaseFactoryFfi,
        path: databasePath,
      );
      upgraded = upgradedDb;

      final rows = await upgradedDb.pending();
      expect(upgradedDb.watchId, 'W-TEST');
      expect(rows, hasLength(1));
      expect(rows.single.id, 1);
      expect(rows.single.location, 'Barangay Arnaldo');
      expect(rows.single.injuries, 'Drowning');
      expect(rows.single.rawText, 'Synthetic pending report');
      expect(rows.single.synced, isFalse);
      expect(rows.single.reportId, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(await upgradedDb.pendingCount(), 1);
      expect(await upgradedDb.pendingCloudCount(), 2);
      expect(await upgradedDb.unassignedCloudCount(), 2);

      final verifier = await databaseFactoryFfi.openDatabase(databasePath);
      final migrated = await verifier.query('triage_logs', orderBy: 'id');
      await verifier.close();
      expect(migrated, hasLength(2));
      expect(migrated.map((row) => row['sync_status']), [0, 1]);
      expect(migrated.map((row) => row['cloud_sync_status']), [0, 0]);
      expect(migrated.map((row) => row['cloud_owner_id']), [null, null]);
      expect(migrated.map((row) => row['report_id']).toSet(), hasLength(2));
      await upgradedDb.close();
      upgraded = null;

      final reopenedDb = await TriageDb.open(
        factory: databaseFactoryFfi,
        path: databasePath,
      );
      reopened = reopenedDb;
      expect(reopenedDb.watchId, 'W-TEST');
      expect(
        (await reopenedDb.pending()).single.reportId,
        rows.single.reportId,
      );
    },
  );

  test(
    'restart and clock rollback preserve unique timestamps and exact originals',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vanguard-identity-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'vanguard.db');
      var db = await TriageDb.open(factory: databaseFactoryFfi, path: path);
      await db.insert(const TriageParser().parse('Synthetic original'));
      await db.close();
      final fixture = await databaseFactoryFfi.openDatabase(path);
      final future = DateTime.now()
          .toUtc()
          .add(const Duration(days: 30))
          .toIso8601String();
      await fixture.update('triage_logs', {'created_at': future});
      await fixture.close();
      db = await TriageDb.open(factory: databaseFactoryFfi, path: path);
      try {
        final result = await db.insert(
          const TriageParser().parse('  Synthetic exact original  '),
        );
        expect(
          DateTime.parse(result.createdAt).isAfter(DateTime.parse(future)),
          isTrue,
        );
        expect(result.rawText, '  Synthetic exact original  ');
        expect(
          (await db.pending()).map((row) => row.createdAt).toSet(),
          hasLength(2),
        );
        expect(await db.pendingCount(), 2);
      } finally {
        await db.close();
      }
    },
  );

  test('rolls back an upgrade failure and leaves the v1 data intact', () async {
    final directory = await Directory.systemTemp.createTemp('vanguard-db-');
    addTearDown(() => directory.delete(recursive: true));
    final databasePath = p.join(directory.path, 'vanguard.db');
    await _createVersionOneDatabase(databasePath, conflictIndex: true);

    await expectLater(
      TriageDb.open(factory: databaseFactoryFfi, path: databasePath),
      throwsA(isA<Exception>()),
    );

    final verifier = await databaseFactoryFfi.openDatabase(databasePath);
    final columns = await verifier.rawQuery('PRAGMA table_info(triage_logs)');
    final rows = await verifier.query('triage_logs', orderBy: 'id');
    final version = await verifier.getVersion();
    await verifier.close();
    expect(version, 1);
    expect(
      columns.map((column) => column['name']),
      isNot(contains('report_id')),
    );
    expect(rows, hasLength(2));
    expect(rows.map((row) => row['sync_status']), [0, 1]);
  });
}

Future<void> _createVersionOneDatabase(
  String path, {
  bool conflictIndex = false,
}) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
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
    ),
  );
  if (conflictIndex) {
    await db.execute('CREATE INDEX triage_logs_report_id ON meta(value)');
  }
  await db.insert('meta', {'key': 'watch_id', 'value': 'W-TEST'});
  await db.insert('triage_logs', {
    'location': 'Barangay Arnaldo',
    'injuries': 'Drowning',
    'triage': 'Immediate',
    'patient_count': 2,
    'age_group': 'Child',
    'eta_minutes': 10,
    'raw_text': 'Synthetic pending report',
    'created_at': '2026-10-09T06:00:00.001Z',
    'sync_status': 0,
  });
  await db.insert('triage_logs', {
    'location': 'Barangay Navarro',
    'injuries': 'Fracture',
    'triage': 'Delayed',
    'patient_count': 1,
    'age_group': 'Adult',
    'eta_minutes': null,
    'raw_text': 'Synthetic acknowledged report',
    'created_at': '2026-10-09T06:00:00.002Z',
    'sync_status': 1,
  });
  await db.close();
}
