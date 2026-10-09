import 'dart:async';

import 'package:flutter/material.dart';

import 'db/triage_db.dart';
import 'nlp/triage_parser.dart';
import 'theme.dart';
import 'watch_icon_button.dart';
import 'watch_layout.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// How long ago a report was made: "just now", "5 min ago", "2 h ago", or the
/// date for anything older than a day. [iso] is the report's UTC timestamp.
/// A watch clock that runs ahead of [now] reads as "just now", never negative.
String reportAge(String iso, DateTime now) {
  final t = DateTime.tryParse(iso);
  if (t == null) return '';
  final mins = now.toUtc().difference(t.toUtc()).inMinutes;
  if (mins < 1) return 'just now';
  if (mins < 60) return '$mins min ago';
  if (mins < 24 * 60) return '${mins ~/ 60} h ago';
  final d = t.toLocal();
  return '${d.day} ${_months[d.month - 1]}';
}

String _clock(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return '';
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// The round button on the recording screen that opens the report list. The
/// badge counts every report saved on this watch.
class ReportsButton extends StatelessWidget {
  const ReportsButton({
    super.key,
    required this.count,
    required this.onPressed,
    this.unit = 1,
  });

  final int count;
  final VoidCallback? onPressed;
  final double unit;

  @override
  Widget build(BuildContext context) => WatchIconButton(
    icon: Icons.format_list_bulleted_rounded,
    badge: count,
    unit: unit,
    onPressed: onPressed,
    label: count == 1
        ? 'Show the 1 patient triaged on this watch'
        : 'Show the $count patients triaged on this watch',
  );
}

/// The patients triaged on this watch, newest first. Read-only: it shows what
/// the local database holds and whether the hub has acknowledged each report.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.load,
    this.refreshEvery = const Duration(seconds: 5),
    this.now = DateTime.now,
  });

  final Future<List<TriageRow>> Function() load;

  /// The list re-reads while open, so a report the hub acknowledges flips from
  /// a clock to a check mark without leaving the screen.
  final Duration refreshEvery;
  final DateTime Function() now;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  List<TriageRow>? _rows;
  bool _failed = false;
  int? _open;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(widget.refreshEvery, (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final rows = await widget.load();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true); // keep showing the last list we had
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final rows = _rows;
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final m = WatchMetrics.of(box.biggest);
            final u = m.unit;
            return AdaptiveListFrame(
              metrics: m,
              title: Text(
                rows == null ? 'REPORTS' : 'REPORTS  ·  ${rows.length}',
                style: TextStyle(
                  color: c.text,
                  fontSize: 12 * u,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              list: _list(c, u, rows),
              action: WatchActionButton(
                metrics: m,
                label: 'BACK',
                icon: Icons.arrow_back_rounded,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _list(AppColors c, double u, List<TriageRow>? rows) {
    String? message;
    if (rows == null) {
      message = _failed ? 'COULD NOT READ REPORTS' : 'LOADING…';
    } else if (rows.isEmpty) {
      message = 'NO REPORTS YET\nTap the mic to record one.';
    }
    if (message != null) {
      return Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: c.dim,
            fontSize: 12 * u,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final now = widget.now();
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: rows!.length,
      separatorBuilder: (_, _) => SizedBox(height: 4 * u),
      itemBuilder: (context, i) {
        final row = rows[i];
        return _ReportTile(
          key: ValueKey('report-${row.id}'),
          row: row,
          unit: u,
          age: reportAge(row.createdAt, now),
          open: _open == row.id,
          onTap: () => setState(() => _open = _open == row.id ? null : row.id),
        );
      },
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({
    super.key,
    required this.row,
    required this.unit,
    required this.age,
    required this.open,
    required this.onTap,
  });

  final TriageRow row;
  final double unit;
  final String age;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final style = triageStyle(row.triage, Theme.of(context).brightness);
    final unassessed = row.triage == TriageParser.unassessed;
    final dim = TextStyle(color: c.dim, fontSize: 11 * unit);
    return Material(
      color: c.panel,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 8 * unit,
            vertical: 6 * unit,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 6 * unit,
                        vertical: 2 * unit,
                      ),
                      decoration: BoxDecoration(
                        color: style.background,
                        borderRadius: BorderRadius.circular(6),
                        border: unassessed
                            ? Border.all(color: style.accent)
                            : null,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${row.triage.toUpperCase()}  ×${row.patientCount}',
                          style: TextStyle(
                            color: style.foreground,
                            fontSize: 13 * unit,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    row.synced
                        ? Icons.check_circle_rounded
                        : Icons.schedule_rounded,
                    size: 16 * unit,
                    color: row.synced ? c.accent : c.dim,
                    semanticLabel: row.synced
                        ? 'Hub acknowledged'
                        : 'Waiting for hub',
                  ),
                ],
              ),
              SizedBox(height: 2 * unit),
              Text(
                row.injuries,
                maxLines: open ? null : 1,
                overflow: open ? null : TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13 * unit),
              ),
              Text(
                '${row.location}${age.isEmpty ? '' : ' · $age'}',
                maxLines: open ? null : 1,
                overflow: open ? null : TextOverflow.ellipsis,
                style: dim,
              ),
              if (open) ...[
                if (row.ageGroup != TriageParser.unspecified)
                  Text('Age ${row.ageGroup}', style: dim),
                if (row.etaMinutes != null)
                  Text('ETA ${row.etaMinutes} min', style: dim),
                Text('Reported ${_clock(row.createdAt)}', style: dim),
                Text(
                  row.cloudSynced ? 'Cloud: uploaded' : 'Cloud: not uploaded',
                  style: dim,
                ),
                Text(
                  row.synced ? 'Hub acknowledged' : 'Waiting for hub',
                  style: dim.copyWith(
                    color: row.synced ? c.accent : c.dim,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
