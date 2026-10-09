import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_wrist/db/triage_db.dart';
import 'package:vanguard_wrist/main.dart';
import 'package:vanguard_wrist/theme.dart';
import 'package:vanguard_wrist/watch_layout.dart';

const _header = Key('header');
const _mic = Key('mic');
const _status = Key('status');
const _content = Key('content');
const _action = Key('action');

Future<void> _pump(
  WidgetTester tester,
  Size size, {
  String mode = 'auto',
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LayoutBuilder(
          builder: (context, box) {
            final m = WatchMetrics.of(box.biggest, mode: mode);
            return AdaptiveWatchFrame(
              metrics: m,
              header: const Text(
                'W-3F9A  ·  12 PENDING',
                key: _header,
                style: TextStyle(fontSize: 11, letterSpacing: 1),
              ),
              mic: Container(
                key: _mic,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.teal,
                ),
              ),
              status: const Text(
                'CAPTURE/SAVE FAILED',
                key: _status,
                style: TextStyle(fontSize: 13),
              ),
              content: const SingleChildScrollView(
                key: _content,
                child: Text('One adult, fracture, Pier 4, ETA 25 min'),
              ),
              action: Container(key: _action, color: Colors.teal),
            );
          },
        ),
      ),
    ),
  );
}

bool _insideCircle(Rect r, Size size, {double slack = 1.5}) {
  final c = Offset(size.width / 2, size.height / 2);
  final radius = math.min(size.width, size.height) / 2 + slack;
  return [
    r.topLeft,
    r.topRight,
    r.bottomLeft,
    r.bottomRight,
  ].every((p) => (p - c).distance <= radius);
}

/// The default test font is far wider than Roboto, so text-fit checks use the
/// real font from the Flutter SDK. False when the SDK fonts are not installed.
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

void main() {
  var haveRoboto = false;
  setUpAll(() async => haveRoboto = await _loadRoboto());

  group('shape', () {
    test(
      'a 1:1 screen gets the round-safe layout, other proportions a box layout',
      () {
        expect(
          WatchMetrics.shapeFor(const Size(227, 227), 'auto'),
          WatchShape.round,
        );
        expect(
          WatchMetrics.shapeFor(const Size(240, 280), 'auto'),
          WatchShape.square,
        );
        expect(
          WatchMetrics.shapeFor(const Size(320, 240), 'auto'),
          WatchShape.square,
        );
      },
    );

    test('the build setting forces a shape', () {
      expect(
        WatchMetrics.shapeFor(const Size(227, 227), 'square'),
        WatchShape.square,
      );
      expect(
        WatchMetrics.shapeFor(const Size(240, 280), 'round'),
        WatchShape.round,
      );
    });

    test('sizes scale with the screen but stay in range', () {
      expect(WatchMetrics.of(const Size(100, 100)).unit, 0.8);
      expect(WatchMetrics.of(const Size(200, 200)).unit, 1.0);
      expect(WatchMetrics.of(const Size(900, 900)).unit, 1.5);
      expect(WatchMetrics.of(const Size(320, 240)).wide, isTrue);
      expect(WatchMetrics.of(const Size(240, 280)).wide, isFalse);
    });

    test('the round button never wider than the circle at its edge allows', () {
      for (final d in [160.0, 192.0, 227.0, 280.0, 454.0]) {
        final m = WatchMetrics.of(Size(d, d));
        final bottom = d - m.bottomPad;
        expect(
          m.buttonWidth,
          lessThanOrEqualTo(chordAt(bottom - m.buttonHeight / 2, d)),
          reason: 'diameter $d',
        );
        expect(
          m.headerMaxWidth,
          lessThanOrEqualTo(chordAt(m.topPad, d)),
          reason: 'diameter $d',
        );
      }
    });
  });

  group('round screens', () {
    for (final d in [160.0, 192.0, 227.0, 280.0, 390.0, 454.0]) {
      testWidgets('every part stays inside the circle at ${d.toInt()} px', (
        tester,
      ) async {
        final size = Size(d, d);
        await _pump(tester, size);
        expect(tester.takeException(), isNull, reason: 'no overflow');
        for (final key in [_header, _status, _content]) {
          final r = tester.getRect(find.byKey(key));
          expect(_insideCircle(r, size), isTrue, reason: '$key $r at $d');
        }
        // The round button is a pill: its ends and flat bottom, not its square
        // corners, are what meet the bezel.
        final b = tester.getRect(find.byKey(_action));
        final rad = b.height / 2;
        final centre = Offset(d / 2, d / 2);
        for (final p in [
          Offset(b.left, b.center.dy),
          Offset(b.right, b.center.dy),
          Offset(b.left + rad, b.bottom),
          Offset(b.right - rad, b.bottom),
        ]) {
          expect(
            (p - centre).distance,
            lessThanOrEqualTo(d / 2 + 1.5),
            reason: 'button $b at $d',
          );
        }
        final mic = tester.getRect(find.byKey(_mic));
        final c = Offset(d / 2, d / 2);
        expect(
          (mic.center - c).distance + mic.width / 2,
          lessThanOrEqualTo(d / 2 + 1.5),
          reason: 'mic at $d',
        );
        expect(
          mic.width,
          greaterThan(44),
          reason: 'mic stays easy to tap at $d',
        );
      });
    }

    testWidgets('a round layout on a slightly non-square screen is centred', (
      tester,
    ) async {
      await _pump(tester, const Size(240, 260), mode: 'round');
      expect(tester.takeException(), isNull);
      final mic = tester.getRect(find.byKey(_mic));
      expect(mic.center.dx, closeTo(120, 1));
    });
  });

  group('box screens', () {
    for (final size in const [
      Size(240, 240),
      Size(240, 280),
      Size(280, 340),
      Size(320, 240),
      Size(400, 300),
    ]) {
      testWidgets(
        'uses the whole screen without overflow at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await _pump(
            tester,
            size,
            mode: size.width == size.height ? 'square' : 'auto',
          );
          expect(tester.takeException(), isNull, reason: 'no overflow');
          final screen = Offset.zero & size;
          for (final key in [_header, _mic, _status, _content, _action]) {
            final r = tester.getRect(find.byKey(key));
            expect(
              screen.inflate(1).contains(r.topLeft) &&
                  screen.inflate(1).contains(r.bottomRight),
              isTrue,
              reason: '$key $r',
            );
          }
          // Box screens use the width: the button spans it, unlike the round pill.
          expect(
            tester.getRect(find.byKey(_action)).width,
            greaterThan(size.width * 0.4),
          );
        },
      );
    }

    testWidgets('a wide screen puts the mic beside the text', (tester) async {
      await _pump(tester, const Size(320, 240));
      final mic = tester.getRect(find.byKey(_mic));
      final status = tester.getRect(find.byKey(_status));
      expect(
        mic.right,
        lessThanOrEqualTo(status.left + 1),
        reason: 'mic left of the text',
      );
    });

    testWidgets('a tall screen stacks the mic above the text', (tester) async {
      await _pump(tester, const Size(240, 320));
      final mic = tester.getRect(find.byKey(_mic));
      final status = tester.getRect(find.byKey(_status));
      expect(
        mic.bottom,
        lessThanOrEqualTo(status.top + 1),
        reason: 'mic above the status',
      );
    });
  });

  group('saved report card', () {
    // Worst realistic case: the longest category chip, two findings, a place and an ETA.
    const row = TriageRow(
      id: 1,
      location: 'Barangay Arnaldo',
      injuries: 'Drowning, Unconscious',
      triage: 'Immediate',
      patientCount: 2,
      ageGroup: 'Child',
      etaMinutes: 10,
      rawText: 'synthetic',
      createdAt: '2026-10-09T12:00:00.000Z',
      synced: false,
    );

    for (final d in [192.0, 227.0, 280.0, 390.0, 454.0]) {
      testWidgets(
        'is readable without scrolling on a ${d.toInt()} px round screen',
        (tester) async {
          if (!haveRoboto) {
            markTestSkipped('Roboto is not in the Flutter SDK cache');
            return;
          }
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(d, d);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(Brightness.dark),
              home: Scaffold(
                body: LayoutBuilder(
                  builder: (context, box) {
                    final m = WatchMetrics.of(box.biggest);
                    return AdaptiveWatchFrame(
                      metrics: m,
                      compactMic: true,
                      header: const Text('W-3F9A  ·  1 PENDING'),
                      mic: Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.teal,
                        ),
                      ),
                      status: const Text('HUB ACKNOWLEDGED'),
                      content: SavedCard(row: row, unit: m.unit),
                      action: Container(color: Colors.teal),
                    );
                  },
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'no overflow');
          final scroll = tester.state<ScrollableState>(
            find.descendant(
              of: find.byType(SavedCard),
              matching: find.byType(Scrollable),
            ),
          );
          expect(
            scroll.position.maxScrollExtent,
            lessThanOrEqualTo(0.5),
            reason: 'findings and pickup point need no scrolling at $d',
          );
          final chip = tester.getRect(find.textContaining('IMMEDIATE'));
          expect(
            chip.height,
            lessThan(30 * (d / 200).clamp(0.8, 1.5)),
            reason: 'chip stays on one line at $d',
          );
        },
      );
    }
  });

  group('side button beside the mic', () {
    Future<void> pumpWithSide(
      WidgetTester tester,
      Size size, {
      String mode = 'auto',
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayoutBuilder(
              builder: (context, box) {
                final m = WatchMetrics.of(box.biggest, mode: mode);
                return AdaptiveWatchFrame(
                  metrics: m,
                  header: const Text('W-3F9A  ·  1 PENDING'),
                  mic: Container(
                    key: _mic,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.teal,
                    ),
                  ),
                  status: const Text('TAP TO REPORT'),
                  content: const SizedBox(),
                  action: const SizedBox(),
                  sideAction: Container(
                    key: const Key('side'),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.orange,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    for (final d in [160.0, 192.0, 227.0, 280.0, 454.0]) {
      testWidgets(
        'sits inside the circle and clear of the mic at ${d.toInt()} px',
        (tester) async {
          await pumpWithSide(tester, Size(d, d));
          expect(tester.takeException(), isNull);
          final side = tester.getRect(find.byKey(const Key('side')));
          final mic = tester.getRect(find.byKey(_mic));
          final c = Offset(d / 2, d / 2);
          expect(
            (side.center - c).distance + side.width / 2,
            lessThanOrEqualTo(d / 2 + 1.5),
            reason: 'button inside the bezel at $d',
          );
          expect(
            side.overlaps(mic),
            isFalse,
            reason: 'button clear of mic at $d',
          );
          expect(
            side.width,
            greaterThanOrEqualTo(36),
            reason: 'tappable at $d',
          );
          expect(
            (mic.center.dx - d / 2).abs(),
            lessThan(1),
            reason: 'mic stays centred at $d',
          );
        },
      );
    }

    for (final size in const [Size(240, 300), Size(320, 240), Size(240, 240)]) {
      testWidgets(
        'is clear of the mic on a ${size.width.toInt()}x${size.height.toInt()} box',
        (tester) async {
          await pumpWithSide(
            tester,
            size,
            mode: size.width == size.height ? 'square' : 'auto',
          );
          expect(tester.takeException(), isNull);
          final side = tester.getRect(find.byKey(const Key('side')));
          final mic = tester.getRect(find.byKey(_mic));
          expect(side.overlaps(mic), isFalse);
          expect(
            (Offset.zero & size).inflate(1).contains(side.bottomRight),
            isTrue,
          );
          final shorter = math.min(size.width, size.height);
          expect(
            mic.width,
            greaterThanOrEqualTo(shorter * 0.3),
            reason: 'the button does not squeeze the mic on $size',
          );
        },
      );
    }
  });

  group('action button', () {
    testWidgets('keeps its label on one line even in a narrow button', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 240);
      addTearDown(tester.view.reset);
      final m = WatchMetrics.of(const Size(320, 240));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 96,
                height: 36,
                child: WatchActionButton(
                  metrics: m,
                  label: 'RETRY NOW',
                  icon: Icons.local_hospital,
                  onPressed: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final button = tester.getRect(find.byType(FilledButton));
      final label = tester.getRect(find.text('RETRY NOW'));
      expect(label.height, lessThan(14 * m.unit * 1.6), reason: 'one line');
      expect(label.right, lessThanOrEqualTo(button.right + 0.5));
    });

    testWidgets('is a pill on round screens and a rounded box otherwise', (
      tester,
    ) async {
      Future<ShapeBorder?> shapeAt(Size size, String mode) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 120,
                  height: 36,
                  child: WatchActionButton(
                    metrics: WatchMetrics.of(size, mode: mode),
                    label: 'BACK',
                    icon: Icons.arrow_back,
                    onPressed: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        final ink = tester.widget<Material>(
          find.descendant(
            of: find.byType(FilledButton),
            matching: find.byType(Material),
          ),
        );
        return ink.shape;
      }

      expect(
        await shapeAt(const Size(227, 227), 'round'),
        isA<StadiumBorder>(),
      );
      expect(
        await shapeAt(const Size(240, 300), 'square'),
        isNot(isA<StadiumBorder>()),
      );
    });
  });
}
