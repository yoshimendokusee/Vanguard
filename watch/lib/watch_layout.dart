import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shape of the watch display.
enum WatchShape { round, square }

/// Override at build time: `--dart-define=WATCH_SHAPE=round` or `square`.
/// The default, `auto`, picks the shape from the screen proportions.
const _shapeMode = String.fromEnvironment('WATCH_SHAPE', defaultValue: 'auto');

/// Width of a circle of the given [diameter] at height [y] from its top edge.
double chordAt(double y, double diameter) {
  final r = diameter / 2;
  final dy = (r - y).abs();
  return dy >= r ? 0 : 2 * math.sqrt(r * r - dy * dy);
}

/// Sizes and insets for one screen. Pure arithmetic, so it is easy to test.
///
/// Flutter has no portable "is the screen round" flag. A 1:1 screen is either a
/// round or a square display, and the round layout is safe on both (it only
/// leaves larger margins), so 1:1 resolves to round. Any other proportion is a
/// box (rectangular) display. Force either with `WATCH_SHAPE`.
@immutable
class WatchMetrics {
  const WatchMetrics({
    required this.size,
    required this.shape,
    required this.unit,
    required this.wide,
    required this.topPad,
    required this.bottomPad,
    required this.sidePad,
    required this.headerMaxWidth,
    required this.statusMaxWidth,
    required this.buttonWidth,
    required this.buttonHeight,
    required this.sideActionSize,
    required this.sideActionInset,
    required this.listSide,
  });

  factory WatchMetrics.of(Size size, {String mode = _shapeMode}) {
    final shape = shapeFor(size, mode);
    final s = math.min(size.width, size.height);
    final u = (s / 200).clamp(0.8, 1.5).toDouble();
    if (shape == WatchShape.round) {
      final topPad = 0.07 * s;
      final bottomPad = 0.05 * s;
      final buttonHeight = (0.17 * s).clamp(30.0, 52.0).toDouble();
      final bottomEdge = s - bottomPad;
      final buttonWidth = math.min(
        chordAt(bottomEdge - 1, s) + buttonHeight,
        chordAt(bottomEdge - buttonHeight / 2, s) - 6,
      );
      return WatchMetrics(
        size: size,
        shape: shape,
        unit: u,
        wide: false,
        topPad: topPad,
        bottomPad: bottomPad,
        // the text area ends above the button, where the circle is still 85% as wide as it is tall
        sidePad: 0.08 * s,
        // the header's top corners sit at the narrowest part of the circle
        headerMaxWidth: math.max(48, chordAt(topPad, s) - 4 * u),
        statusMaxWidth: 0.84 * s,
        buttonWidth: buttonWidth,
        buttonHeight: buttonHeight,
        sideActionSize: (40 * u).clamp(36.0, 56.0).toDouble(),
        sideActionInset: 0.1 * s,
        // a list starts just below the title, where the circle is about 77% as wide as it is tall
        listSide: 0.12 * s,
      );
    }
    final wide = size.width / size.height > 1.25;
    final side = 8 * u;
    return WatchMetrics(
      size: size,
      shape: shape,
      unit: u,
      wide: wide,
      topPad: 6 * u,
      bottomPad: 6 * u,
      sidePad: side,
      headerMaxWidth: wide
          ? size.width * 5 / 9 - 2 * side
          : size.width - 2 * side,
      statusMaxWidth: wide
          ? size.width * 5 / 9 - 2 * side
          : size.width - 2 * side,
      buttonWidth: double.infinity,
      buttonHeight: 36 * u,
      sideActionSize: (40 * u).clamp(36.0, 56.0).toDouble(),
      sideActionInset: 4 * u,
      listSide: 0,
    );
  }

  static WatchShape shapeFor(Size size, String mode) {
    if (mode == 'round') return WatchShape.round;
    if (mode == 'square') return WatchShape.square;
    final ratio = size.width / size.height;
    return ratio > 0.9 && ratio < 1.1 ? WatchShape.round : WatchShape.square;
  }

  final Size size;
  final WatchShape shape;

  /// Scale factor against a 200 dp reference screen, kept between 0.8 and 1.5.
  final double unit;

  /// A box screen wider than it is tall: mic beside the text instead of above it.
  final bool wide;
  final double topPad;
  final double bottomPad;

  /// Horizontal margin: around the whole body on box screens, around the
  /// report text on round screens.
  final double sidePad;
  final double headerMaxWidth;
  final double statusMaxWidth;
  final double buttonWidth;
  final double buttonHeight;

  /// A round icon button beside the mic, and how far it sits from the screen edge.
  final double sideActionSize;
  final double sideActionInset;

  /// Horizontal inset of a scrolling list on round screens.
  final double listSide;
}

Widget _fitBox(Widget child, double maxWidth) => Center(
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth),
    child: FittedBox(fit: BoxFit.scaleDown, child: child),
  ),
);

Widget _buttonBox(WatchMetrics m, Widget action) => Center(
  child: SizedBox(
    width: m.buttonWidth.isFinite ? m.buttonWidth : double.infinity,
    height: m.buttonHeight,
    child: action,
  ),
);

/// A round screen uses the circle that fits the display, centred.
Widget _inCircle(WatchMetrics m, Widget body) => m.shape == WatchShape.round
    ? Center(
        child: SizedBox.square(
          dimension: math.min(m.size.width, m.size.height),
          child: body,
        ),
      )
    : body;

/// Lays out the watch screen's parts for the screen's shape. The parts are
/// built by the caller, so no recording or saving logic lives here.
class AdaptiveWatchFrame extends StatelessWidget {
  const AdaptiveWatchFrame({
    super.key,
    required this.metrics,
    required this.header,
    required this.mic,
    required this.status,
    required this.content,
    required this.action,
    this.sideAction,
    this.leadingAction,
    this.compactMic = false,
  });

  final WatchMetrics metrics;
  final Widget header;
  final Widget mic;
  final Widget status;
  final Widget content;
  final Widget action;

  /// A round icon button shown to the right of the mic (opens the report list).
  final Widget? sideAction;

  /// A round icon button shown to the left of the mic (the cloud account).
  final Widget? leadingAction;

  /// Give the text more room than the mic (used while a saved report is shown,
  /// so its findings and pickup point are readable without scrolling).
  final bool compactMic;

  Widget _micArea(WatchMetrics m, {required bool withSide}) => LayoutBuilder(
    builder: (context, box) {
      final side = withSide ? sideAction : null;
      final lead = withSide ? leadingAction : null;
      // keep room for a button on both sides so the mic stays centred
      final reserve = side == null && lead == null
          ? 0.0
          : 2 * (m.sideActionSize + m.sideActionInset + 4 * m.unit);
      final d = math.max(0.0, math.min(box.maxHeight, box.maxWidth - reserve));
      Widget button(Widget child, Alignment at) => Align(
        alignment: at,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: m.sideActionInset),
          child: SizedBox.square(dimension: m.sideActionSize, child: child),
        ),
      );
      return Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.square(dimension: d, child: mic),
          if (lead != null) button(lead, Alignment.centerLeft),
          if (side != null) button(side, Alignment.centerRight),
        ],
      );
    },
  );

  /// On a wide screen the mic column is narrow, so the round buttons sit in a
  /// row under the mic instead of beside it.
  Widget _wideMicColumn(WatchMetrics m) {
    final buttons = [?leadingAction, ?sideAction];
    return Column(
      children: [
        Expanded(child: _micArea(m, withSide: false)),
        if (buttons.isNotEmpty) ...[
          SizedBox(height: 3 * m.unit),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) SizedBox(width: 8 * m.unit),
                SizedBox.square(dimension: m.buttonHeight, child: buttons[i]),
              ],
            ],
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    final round = m.shape == WatchShape.round;
    final gap = 3 * m.unit;
    final Widget body;
    if (m.wide) {
      body = Padding(
        padding: EdgeInsets.fromLTRB(
          m.sidePad,
          m.topPad,
          m.sidePad,
          m.bottomPad,
        ),
        child: Row(
          children: [
            Expanded(flex: 4, child: _wideMicColumn(m)),
            SizedBox(width: 2 * gap),
            Expanded(
              flex: 5,
              child: Column(
                children: [
                  _fitBox(header, m.headerMaxWidth),
                  SizedBox(height: gap),
                  _fitBox(status, m.statusMaxWidth),
                  Expanded(child: content),
                  _buttonBox(m, action),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      body = Padding(
        padding: EdgeInsets.fromLTRB(
          round ? 0 : m.sidePad,
          m.topPad,
          round ? 0 : m.sidePad,
          m.bottomPad,
        ),
        child: Column(
          children: [
            _fitBox(header, m.headerMaxWidth),
            SizedBox(height: gap),
            Expanded(
              flex: compactMic ? 3 : 5,
              child: _micArea(m, withSide: true),
            ),
            SizedBox(height: gap),
            _fitBox(status, m.statusMaxWidth),
            Expanded(
              flex: compactMic ? 5 : 3,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: round ? m.sidePad : 0,
                ),
                child: content,
              ),
            ),
            _buttonBox(m, action),
          ],
        ),
      );
    }
    return _inCircle(m, body);
  }
}

/// A title, a scrolling list and one button, laid out for the screen's shape.
class AdaptiveListFrame extends StatelessWidget {
  const AdaptiveListFrame({
    super.key,
    required this.metrics,
    required this.title,
    required this.list,
    required this.action,
  });

  final WatchMetrics metrics;
  final Widget title;
  final Widget list;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    final round = m.shape == WatchShape.round;
    final gap = 3 * m.unit;
    final body = Padding(
      padding: EdgeInsets.fromLTRB(
        round ? 0 : m.sidePad,
        m.topPad,
        round ? 0 : m.sidePad,
        m.bottomPad,
      ),
      child: Column(
        children: [
          // On a round screen the list starts 19% of the way down, where the
          // circle is wide enough for it; the title is centred in the space above.
          if (round)
            SizedBox(
              height: 0.19 * math.min(m.size.width, m.size.height) - m.topPad,
              child: _fitBox(title, m.headerMaxWidth),
            )
          else ...[
            _fitBox(title, m.headerMaxWidth),
            SizedBox(height: gap),
          ],
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: m.listSide),
              child: list,
            ),
          ),
          SizedBox(height: gap),
          _buttonBox(m, action),
        ],
      ),
    );
    return _inCircle(m, body);
  }
}

/// The one wide button at the bottom of a watch screen. Its label stays on one
/// line and shrinks if the button is narrow (for example beside the reports
/// button on a wide screen). Round screens get a pill shape.
class WatchActionButton extends StatelessWidget {
  const WatchActionButton({
    super.key,
    required this.metrics,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.compact = false,
    this.semanticLabel,
  });

  final WatchMetrics metrics;
  final String label;

  /// Read aloud instead of [label] when the visible text is shortened.
  final String? semanticLabel;
  final IconData icon;
  final VoidCallback? onPressed;

  /// Smaller icon and label, for two buttons sharing one row.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final u = metrics.unit;
    final round = metrics.shape == WatchShape.round;
    final style = round || compact
        ? FilledButton.styleFrom(
            shape: round ? const StadiumBorder() : null,
            padding: EdgeInsets.symmetric(horizontal: (compact ? 4 : 8) * u),
          )
        : null;
    return FilledButton.icon(
      style: style,
      onPressed: onPressed,
      icon: Icon(icon, size: (compact ? 14 : 18) * u),
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          semanticsLabel: semanticLabel,
          maxLines: 1,
          style: TextStyle(fontSize: (compact ? 11 : 14) * u),
        ),
      ),
    );
  }
}
