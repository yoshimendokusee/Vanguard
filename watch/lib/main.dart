import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';

import 'db/triage_db.dart';
import 'nlp/triage_parser.dart';
import 'reports_screen.dart';
import 'services/speech_service.dart';
import 'services/sync_service.dart';
import 'theme.dart';
import 'watch_layout.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VanguardWristApp());
}

class VanguardWristApp extends StatelessWidget {
  const VanguardWristApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Vanguard-Wrist',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: const TriageScreen(),
  );
}

enum _Phase { loading, idle, listening, processing, error }

class TriageScreen extends StatefulWidget {
  const TriageScreen({super.key});

  @override
  State<TriageScreen> createState() => _TriageScreenState();
}

class _TriageScreenState extends State<TriageScreen>
    with WidgetsBindingObserver {
  static const _parser = TriageParser();

  final _speech = OfflineSpeech();
  final _scroll = ScrollController();

  TriageDb? _db;
  SyncService? _sync;

  _Phase _phase = _Phase.loading;
  String _transcript = '';
  String _status = 'LOADING MODEL…';
  TriageRow? _lastSaved;
  int _pending = 0;
  int _total = 0; // every report saved on this watch
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _speech.onTranscript = (t) {
      if (!mounted) return;
      setState(() => _transcript = t);
      // Keep the newest words visible as the rescuer keeps talking.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    };
    _boot();
  }

  Future<void> _boot() async {
    try {
      final db = await TriageDb.open();
      _db = db;
      _sync = SyncService(
        watchId: db.watchId,
        pending: db.pending,
        acknowledge: db.markSynced,
      );
      _sync!.start(_syncFinished);
      _pending = await db.pendingCount();
      _total = await db.totalCount();
      await _speech.init();
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _status = 'TAP TO REPORT';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _status = 'MODEL ERROR';
        _transcript = '$e';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync?.dispose();
    _speech.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_phase == _Phase.listening) {
      await _finish();
    } else if (_phase == _Phase.idle) {
      setState(() {
        _phase = _Phase.listening;
        _status = 'LISTENING…';
        _transcript = '';
        _lastSaved = null;
      });
      try {
        await _speech.start();
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _phase = _Phase.error;
          _status = 'MICROPHONE FAILED';
        });
      }
    }
  }

  Future<void> _finish() async {
    setState(() {
      _phase = _Phase.processing;
      _status = 'SAVING…';
    });
    try {
      final text = await _speech.stop();
      await _process(text);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _status = 'CAPTURE/SAVE FAILED';
      });
    }
  }

  /// Transcript -> deterministic parse -> SQLite -> haptic confirmation.
  Future<void> _process(String text) async {
    if (text.trim().isEmpty) {
      await _buzz(_Buzz.nothing);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _status = 'NOTHING HEARD';
      });
      return;
    }
    final result = _parser.parse(text);
    final row = await _db!.insert(result);
    final pending = await _db!.pendingCount();
    final total = await _db!.totalCount();
    await _buzz(
      !result.isRecognized
          ? _Buzz.unrecognized
          : result.triage == TriageParser.immediate
          ? _Buzz.immediate
          : _Buzz.saved,
    );
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _lastSaved = row;
      _pending = pending;
      _total = total;
      _status = result.isRecognized ? 'SAVED' : 'SAVED – CHECK';
    });
    unawaited(_sync!.sync());
  }

  /// Demo fail-safe: long-press the header to run a sample report through the
  /// full parse/save pipeline without using the microphone.
  Future<void> _demoPhrase() async {
    if (_phase != _Phase.idle) return;
    const phrase =
        'Dalawang bata, nalunod at walang malay, sa Barangay '
        'Arnaldo, sampung minuto papunta sa ospital.';
    setState(() {
      _phase = _Phase.processing;
      _transcript = phrase;
    });
    await _process(phrase);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _sync != null) {
      unawaited(_sync!.sync());
    }
  }

  void _syncFinished(SyncOutcome outcome) {
    unawaited(_showSyncOutcome(outcome));
  }

  Future<void> _showSyncOutcome(SyncOutcome outcome) async {
    final pending = await _db!.pendingCount();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _pending = pending;
      if (_phase == _Phase.idle &&
          (pending > 0 || outcome.sent + outcome.duplicates > 0)) {
        _status = pending > 0
            ? outcome.error?.toUpperCase() ?? 'SAVED · RETRYING'
            : 'HUB ACKNOWLEDGED';
      }
    });
  }

  /// The patients triaged on this watch. The list re-reads while it is open;
  /// on return the pending count is refreshed in case the hub acknowledged some.
  Future<void> _openReports() async {
    final db = _db;
    if (db == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReportsScreen(load: () => db.recent()),
      ),
    );
    final pending = await db.pendingCount();
    if (!mounted) return;
    setState(() => _pending = pending);
  }

  Future<void> _doSync() async {
    if (_syncing || _sync == null) return;
    setState(() => _syncing = true);
    await _sync!.sync();
  }

  @override
  Widget build(BuildContext context) {
    final listening = _phase == _Phase.listening;
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        // Round, square and rectangular watches share one set of parts; the
        // frame decides where they sit so nothing is cut off by the bezel.
        child: LayoutBuilder(
          builder: (context, box) {
            final m = WatchMetrics.of(box.biggest);
            final u = m.unit;
            return AdaptiveWatchFrame(
              metrics: m,
              compactMic: _lastSaved != null && !listening,
              sideAction: ReportsButton(
                count: _total,
                unit: u,
                onPressed: _db != null && !listening ? _openReports : null,
              ),
              header: GestureDetector(
                onLongPress: _demoPhrase,
                child: Text(
                  '${_db?.watchId ?? '…'}  ·  $_pending PENDING',
                  style: TextStyle(
                    color: c.dim,
                    fontSize: 11 * u,
                    letterSpacing: 1,
                  ),
                ),
              ),
              mic: Semantics(
                button: true,
                label: listening
                    ? 'Stop and save report'
                    : 'Start dictating a patient report',
                child: GestureDetector(
                  onTap: _toggle,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // Idle is teal on purpose: red/amber/green mean
                      // triage categories on this screen.
                      color: listening
                          ? c.listening
                          : _phase == _Phase.idle
                          ? c.accent
                          : c.panel,
                      border: Border.all(color: c.text, width: 4 * u),
                    ),
                    child: LayoutBuilder(
                      builder: (context, mic) => Icon(
                        listening ? Icons.stop_rounded : Icons.mic_rounded,
                        size: mic.biggest.shortestSide * 0.45,
                        color: listening
                            ? c.onListening
                            : _phase == _Phase.idle
                            ? c.onAccent
                            : c.dim,
                      ),
                    ),
                  ),
                ),
              ),
              status: Text(
                _status,
                style: TextStyle(
                  fontSize: 13 * u,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              content: _lastSaved != null && !listening
                  ? SavedCard(row: _lastSaved!, unit: u)
                  : SingleChildScrollView(
                      controller: _scroll,
                      child: Text(
                        _transcript,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14 * u, height: 1.25),
                      ),
                    ),
              action: WatchActionButton(
                metrics: m,
                label: 'RETRY NOW',
                icon: Icons.local_hospital,
                onPressed: _syncing || listening ? null : _doSync,
              ),
            );
          },
        ),
      ),
    );
  }

  // --- haptics -------------------------------------------------------------

  Future<void> _buzz(_Buzz kind) async {
    if (!(await Vibration.hasVibrator())) return;
    switch (kind) {
      case _Buzz.saved:
        return Vibration.vibrate(pattern: [0, 150, 100, 150]);
      case _Buzz.immediate:
        return Vibration.vibrate(pattern: [0, 300, 100, 300, 100, 300]);
      case _Buzz.unrecognized:
        return Vibration.vibrate(pattern: [0, 80, 80, 80, 80, 80, 80, 80]);
      case _Buzz.nothing:
        return Vibration.vibrate(duration: 700);
    }
  }
}

/// saved = 2 short · immediate = 3 long · unrecognized = 4 rapid · nothing = 1 long
enum _Buzz { saved, immediate, unrecognized, nothing }

/// The report that was just saved. The category chip and pickup line stay on
/// one line (they shrink on small screens) so nothing important wraps or hides.
class SavedCard extends StatelessWidget {
  const SavedCard({super.key, required this.row, this.unit = 1});
  final TriageRow row;
  final double unit;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final style = triageStyle(row.triage, Theme.of(context).brightness);
    final unassessed = row.triage == TriageParser.unassessed;
    final age = row.ageGroup == TriageParser.unspecified
        ? ''
        : ' · ${row.ageGroup}';
    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: 10 * unit,
              vertical: 3 * unit,
            ),
            decoration: BoxDecoration(
              color: style.background,
              borderRadius: BorderRadius.circular(8),
              border: unassessed ? Border.all(color: style.accent) : null,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${row.triage.toUpperCase()}  ×${row.patientCount}$age',
                style: TextStyle(
                  color: style.foreground,
                  fontSize: 17 * unit,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            row.injuries,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14 * unit),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${row.location}'
              '${row.etaMinutes != null ? ' · ETA ${row.etaMinutes} min' : ''}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12 * unit, color: c.dim),
            ),
          ),
        ],
      ),
    );
  }
}
