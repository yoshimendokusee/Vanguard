import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_wrist/db/triage_db.dart';
import 'package:vanguard_wrist/reports_screen.dart';
import 'package:vanguard_wrist/theme.dart';

Future<bool> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return false;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final files = ['Roboto-Regular.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf'];
  if (!files.every((f) => File('$dir/$f').existsSync())) return false;
  final loader = FontLoader('Roboto');
  for (final f in files) {
    loader.addFont(
      Future.value(ByteData.sublistView(File('$dir/$f').readAsBytesSync())),
    );
  }
  await loader.load();
  return true;
}

final _now = DateTime.utc(2026, 10, 9, 12);

String _ago(int minutes) =>
    _now.subtract(Duration(minutes: minutes)).toIso8601String();

TriageRow _row(
  int id,
  String triage,
  int n, {
  String age = 'Adult',
  String injuries = 'Fracture',
  String location = 'Camp 2',
  int? eta = 25,
  int minutesAgo = 3,
  bool synced = false,
}) => TriageRow(
  id: id,
  location: location,
  injuries: injuries,
  triage: triage,
  patientCount: n,
  ageGroup: age,
  etaMinutes: eta,
  rawText: 'synthetic',
  createdAt: _ago(minutesAgo),
  synced: synced,
);

// Newest first, as the database returns them.
List<TriageRow> _sample() => [
  _row(
    8,
    'Immediate',
    2,
    age: 'Child',
    injuries: 'Drowning, Unconscious',
    location: 'Barangay Arnaldo',
    eta: 10,
    minutesAgo: 1,
  ),
  _row(7, 'Delayed', 1, minutesAgo: 6, synced: true),
  _row(
    6,
    'Unassessed',
    1,
    age: 'Unspecified',
    injuries: 'Unspecified',
    location: 'North gate',
    eta: null,
    minutesAgo: 14,
  ),
  _row(
    5,
    'Minor',
    3,
    injuries: 'Laceration',
    location: 'Pier 4',
    minutesAgo: 70,
    synced: true,
  ),
  _row(4, 'Delayed', 2, minutesAgo: 200, synced: true),
  _row(3, 'Minor', 1, minutesAgo: 60 * 30, synced: true),
];

Widget _app(
  Future<List<TriageRow>> Function() load, {
  Duration refresh = const Duration(seconds: 5),
}) => MaterialApp(
  theme: buildTheme(Brightness.dark),
  home: DefaultTextStyle.merge(
    style: const TextStyle(fontFamily: 'Roboto'),
    child: ReportsScreen(load: load, refreshEvery: refresh, now: () => _now),
  ),
);

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Future<void> _end(WidgetTester tester) => tester.pumpWidget(const SizedBox());

void main() {
  var haveRoboto = false;
  setUpAll(() async => haveRoboto = await _loadRoboto());

  group('reportAge', () {
    test('says how long ago in plain words', () {
      expect(reportAge(_ago(0), _now), 'just now');
      expect(reportAge(_ago(5), _now), '5 min ago');
      expect(reportAge(_ago(59), _now), '59 min ago');
      expect(reportAge(_ago(60), _now), '1 h ago');
      expect(reportAge(_ago(23 * 60 + 59), _now), '23 h ago');
    });

    test('older than a day shows the date', () {
      expect(
        reportAge(DateTime.utc(2026, 10, 7, 12).toIso8601String(), _now),
        matches(RegExp(r'^\d{1,2} Oct$')),
      );
    });

    test('a watch clock ahead of the time now never shows a negative age', () {
      expect(
        reportAge(_now.add(const Duration(hours: 3)).toIso8601String(), _now),
        'just now',
      );
    });

    test('a bad timestamp gives no age instead of an error', () {
      expect(reportAge('not a date', _now), '');
    });
  });

  group('list', () {
    testWidgets('shows the newest report first with its status', (
      tester,
    ) async {
      await _size(tester, const Size(280, 280));
      await tester.pumpWidget(_app(() async => _sample()));
      await tester.pump();
      expect(find.text('REPORTS  ·  6'), findsOneWidget);
      final tiles = find.byType(InkWell);
      expect(tiles, findsWidgets);
      final first = tester.getRect(find.byKey(const ValueKey('report-8')));
      final second = tester.getRect(find.byKey(const ValueKey('report-7')));
      expect(first.top, lessThan(second.top), reason: 'newest on top');
      expect(find.byIcon(Icons.schedule_rounded), findsWidgets);
      expect(find.byIcon(Icons.check_circle_rounded), findsWidgets);
      expect(
        find.textContaining('Barangay Arnaldo · 1 min ago'),
        findsOneWidget,
      );
      await _end(tester);
    });

    testWidgets('an empty watch says so', (tester) async {
      await _size(tester, const Size(240, 240));
      await tester.pumpWidget(_app(() async => []));
      await tester.pump();
      expect(find.textContaining('NO REPORTS YET'), findsOneWidget);
      await _end(tester);
    });

    testWidgets('a failed read says so, and keeps the last list once loaded', (
      tester,
    ) async {
      await _size(tester, const Size(240, 240));
      var fail = true;
      await tester.pumpWidget(
        _app(() async {
          if (fail) throw StateError('db closed');
          return _sample();
        }, refresh: const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(find.text('COULD NOT READ REPORTS'), findsOneWidget);
      fail = false;
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('REPORTS  ·  6'), findsOneWidget);
      fail = true;
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        find.text('REPORTS  ·  6'),
        findsOneWidget,
        reason: 'the list stays when a later read fails',
      );
      await _end(tester);
    });

    testWidgets('a report the hub acknowledges flips to a check mark', (
      tester,
    ) async {
      await _size(tester, const Size(240, 240));
      var acknowledged = false;
      await tester.pumpWidget(
        _app(
          () async => [_row(1, 'Immediate', 1, synced: acknowledged)],
          refresh: const Duration(milliseconds: 100),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      acknowledged = true;
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(find.byIcon(Icons.schedule_rounded), findsNothing);
      await _end(tester);
    });

    testWidgets('tapping a report opens its details, tapping again closes', (
      tester,
    ) async {
      await _size(tester, const Size(280, 280));
      await tester.pumpWidget(_app(() async => _sample()));
      await tester.pump();
      final key = find.byKey(const ValueKey('report-8'));
      final closed = tester.getSize(key).height;
      expect(find.text('ETA 10 min'), findsNothing);
      await tester.tap(key);
      await tester.pump();
      expect(find.text('ETA 10 min'), findsOneWidget);
      expect(find.text('Age Child'), findsOneWidget);
      expect(find.text('Waiting for hub'), findsOneWidget);
      expect(tester.getSize(key).height, greaterThan(closed));
      await tester.tap(key);
      await tester.pump();
      expect(find.text('ETA 10 min'), findsNothing);
      await _end(tester);
    });

    for (final d in [192.0, 227.0, 280.0, 454.0]) {
      testWidgets('stays inside the circle at ${d.toInt()} px', (tester) async {
        if (!haveRoboto) {
          markTestSkipped('Roboto is not in the Flutter SDK cache');
          return;
        }
        await _size(tester, Size(d, d));
        await tester.pumpWidget(_app(() async => _sample()));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'no overflow');
        final centre = Offset(d / 2, d / 2);
        bool inside(Rect r) => [
          r.topLeft,
          r.topRight,
          r.bottomLeft,
          r.bottomRight,
        ].every((p) => (p - centre).distance <= d / 2 + 1.5);
        expect(
          inside(tester.getRect(find.byType(ListView))),
          isTrue,
          reason: 'list at $d',
        );
        expect(
          inside(tester.getRect(find.text('REPORTS  ·  6'))),
          isTrue,
          reason: 'title at $d',
        );
        // the first report is fully visible, not clipped by the list edge
        final list = tester.getRect(find.byType(ListView));
        final first = tester.getRect(find.byKey(const ValueKey('report-8')));
        expect(first.top, greaterThanOrEqualTo(list.top - 0.5));
        expect(first.bottom, lessThanOrEqualTo(list.bottom + 0.5));
        // the back button is a pill whose ends and flat bottom meet the bezel
        final b = tester.getRect(find.byType(FilledButton));
        final rad = b.height / 2;
        for (final p in [
          Offset(b.left, b.center.dy),
          Offset(b.right, b.center.dy),
          Offset(b.left + rad, b.bottom),
          Offset(b.right - rad, b.bottom),
        ]) {
          expect((p - centre).distance, lessThanOrEqualTo(d / 2 + 1.5));
        }
        await _end(tester);
      });
    }

    testWidgets('uses the whole screen on a box watch', (tester) async {
      await _size(tester, const Size(240, 300));
      await tester.pumpWidget(_app(() async => _sample()));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final list = tester.getRect(find.byType(ListView));
      expect(list.width, greaterThan(240 * 0.85));
      await _end(tester);
    });
  });

  group('reports button', () {
    Future<void> pumpButton(
      WidgetTester tester,
      int count,
      VoidCallback? onPressed,
    ) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 44,
              child: ReportsButton(count: count, onPressed: onPressed),
            ),
          ),
        ),
      ),
    );

    testWidgets('shows how many reports, capped at 99+', (tester) async {
      await pumpButton(tester, 3, () {});
      expect(find.text('3'), findsOneWidget);
      await pumpButton(tester, 250, () {});
      expect(find.text('99+'), findsOneWidget);
      await pumpButton(tester, 0, () {});
      expect(find.text('0'), findsNothing, reason: 'no badge when empty');
    });

    testWidgets('the badge is a small corner dot and leaves the icon visible', (
      tester,
    ) async {
      await pumpButton(tester, 12, () {});
      final button = tester.getRect(find.byType(ReportsButton));
      // the badge is the rounded box around the number, not the number itself
      final badge = tester.getRect(
        find
            .ancestor(of: find.text('12'), matching: find.byType(Container))
            .first,
      );
      expect(badge.width, lessThan(button.width * 0.6));
      expect(badge.height, lessThan(button.height * 0.6));
      final icon = tester.getRect(
        find.byIcon(Icons.format_list_bulleted_rounded),
      );
      expect(icon.width, greaterThan(0));
      expect(
        icon.overlaps(badge) && icon.intersect(badge).width > icon.width * 0.5,
        isFalse,
        reason: 'the badge does not cover the icon',
      );
    });

    testWidgets('does nothing while disabled, opens when enabled', (
      tester,
    ) async {
      var taps = 0;
      await pumpButton(tester, 2, null);
      await tester.tap(find.byType(ReportsButton));
      expect(taps, 0);
      await pumpButton(tester, 2, () => taps++);
      await tester.tap(find.byType(ReportsButton));
      expect(taps, 1);
    });

    testWidgets('has a spoken label with the count', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpButton(tester, 1, () {});
      expect(
        find.bySemanticsLabel('Show the 1 patient triaged on this watch'),
        findsOneWidget,
      );
      await pumpButton(tester, 4, () {});
      expect(
        find.bySemanticsLabel('Show the 4 patients triaged on this watch'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  test('the circle maths used by the tests is sound', () {
    expect(math.sqrt(2) * 100, closeTo(141.42, 0.01));
  });
}
