import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vanguard_wrist/db/triage_db.dart';
import 'package:vanguard_wrist/nlp/triage_parser.dart';

TriageResult _report(String triage, int n, String place) => TriageResult(
  location: place,
  injuries: const ['Fracture'],
  triage: triage,
  patientCount: n,
  ageGroup: 'Adult',
  etaMinutes: 20,
  rawText: 'Synthetic report',
);

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late TriageDb db;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vanguard-recent-');
    db = await TriageDb.open(
      factory: databaseFactoryFfi,
      path: p.join(directory.path, 'vanguard.db'),
    );
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('an empty watch has no reports and a total of zero', () async {
    expect(await db.recent(), isEmpty);
    expect(await db.totalCount(), 0);
  });

  test('recent lists the newest report first, with every field', () async {
    await db.insert(_report('Minor', 1, 'Pier 4'));
    await db.insert(_report('Delayed', 2, 'Camp 2'));
    await db.insert(_report('Immediate', 3, 'Ridge Trail'));
    final rows = await db.recent();
    expect(rows.map((r) => r.location), ['Ridge Trail', 'Camp 2', 'Pier 4']);
    expect(rows.first.triage, 'Immediate');
    expect(rows.first.patientCount, 3);
    expect(rows.first.reportId, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(await db.totalCount(), 3);
  });

  test(
    'the limit keeps the newest and the total still counts them all',
    () async {
      for (var i = 1; i <= 5; i++) {
        await db.insert(_report('Minor', 1, 'Place $i'));
      }
      final rows = await db.recent(limit: 2);
      expect(rows.map((r) => r.location), ['Place 5', 'Place 4']);
      expect(await db.totalCount(), 5);
    },
  );

  test(
    'acknowledged reports stay in the list; pending ones still count',
    () async {
      final a = await db.insert(_report('Immediate', 1, 'A'));
      await db.insert(_report('Minor', 1, 'B'));
      await db.markSynced([a.id]);
      final rows = await db.recent();
      expect(rows.firstWhere((r) => r.location == 'A').synced, isTrue);
      expect(rows.firstWhere((r) => r.location == 'B').synced, isFalse);
      expect(
        await db.pendingCount(),
        1,
        reason: 'reading the list changes nothing',
      );
      expect(await db.totalCount(), 2);
    },
  );

  test(
    'reading the list does not change what is queued for the hospital',
    () async {
      await db.insert(_report('Delayed', 1, 'A'));
      final before = (await db.pending()).map((r) => r.id).toList();
      await db.recent();
      await db.totalCount();
      expect((await db.pending()).map((r) => r.id).toList(), before);
    },
  );
}
