import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';

import 'db/triage_db.dart';
import 'nlp/triage_parser.dart';
import 'services/speech_service.dart';
import 'services/sync_service.dart';
import 'theme.dart';

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
    theme: ThemeData.dark(useMaterial3: true),
    home: const TriageScreen(),
  );
}

/// START colours.
Color triageColor(String triage) => switch (triage) {
  TriageParser.immediate => const Color(0xFFFF1744),
  TriageParser.delayed => const Color(0xFFFFD600),
  TriageParser.minor => const Color(0xFF00E676),
  TriageParser.deceased => const Color(0xFFB0BEC5),
  _ => Colors.white, // Unassessed
};

enum _Phase { loading, idle, listening, error }

class TriageScreen extends StatefulWidget {
  const TriageScreen({super.key});

  @override
  State<TriageScreen> createState() => _TriageScreenState();
}

class _TriageScreenState extends State<TriageScreen> {
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
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _speech.onTranscript = (t) {
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
      _sync = SyncService(db);
      _pending = await db.pendingCount();
      await _speech.init();
      setState(() {
        _phase = _Phase.idle;
        _status = 'TAP TO REPORT';
      });
    } catch (e) {
      setState(() {
        _phase = _Phase.error;
        _status = 'MODEL ERROR';
        _transcript = '$e';
      });
    }
  }

  @override
  void dispose() {
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
      await _speech.start();
    }
  }

  Future<void> _finish() async {
    setState(() => _status = 'SAVING…');
    final text = await _speech.stop();
    await _process(text);
  }

  /// Transcript -> deterministic parse -> SQLite -> haptic confirmation.
  Future<void> _process(String text) async {
    if (text.trim().isEmpty) {
      await _buzz(_Buzz.nothing);
      setState(() {
        _phase = _Phase.idle;
        _status = 'NOTHING HEARD';
      });
      return;
    }
    final result = _parser.parse(text);
    final row = await _db!.insert(result);
    final pending = await _db!.pendingCount();
    await _buzz(
      !result.isRecognized
          ? _Buzz.unrecognized
          : result.triage == TriageParser.immediate
          ? _Buzz.immediate
          : _Buzz.saved,
    );
    setState(() {
      _phase = _Phase.idle;
      _lastSaved = row;
      _pending = pending;
      _status = result.isRecognized ? 'SAVED' : 'SAVED – CHECK';
    });
  }

  /// Demo fail-safe: long-press the header to run a sample report through the
  /// full parse/save pipeline without using the microphone.
  Future<void> _demoPhrase() async {
    if (_phase != _Phase.idle) return;
    const phrase =
        'Dalawang bata, nalunod at walang malay, sa Barangay '
        'Arnaldo, sampung minuto papunta sa ospital.';
    setState(() => _transcript = phrase);
    await _process(phrase);
  }

  Future<void> _doSync() async {
    if (_syncing || _sync == null) return;
    setState(() {
      _syncing = true;
      _status = 'SENDING…';
    });
    final outcome = await _sync!.sync();
    final pending = await _db!.pendingCount();
    if (outcome.ok) await _buzz(_Buzz.saved);
    setState(() {
      _syncing = false;
      _pending = pending;
      _status = outcome.ok
          ? (outcome.sent + outcome.duplicates == 0
                ? 'NOTHING TO SEND'
                : 'SENT ${outcome.sent}'
                      '${outcome.duplicates > 0 ? ' (${outcome.duplicates} dup)' : ''}')
          : outcome.error!.toUpperCase();
    });
  }

  @override
  Widget build(BuildContext context) {
    final listening = _phase == _Phase.listening;
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Column(
            children: [
              GestureDetector(
                onLongPress: _demoPhrase,
                child: Text(
                  '${_db?.watchId ?? '…'}  ·  $_pending PENDING',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    letterSpacing: 1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                flex: 5,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Semantics(
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
                                ? const Color(0xFF00E5FF)
                                : Colors.grey.shade800,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          child: Icon(
                            listening ? Icons.stop_rounded : Icons.mic_rounded,
                            size: 64,
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
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _status,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              Expanded(
                flex: 3,
                child: _lastSaved != null && !listening
                    ? _SavedCard(row: _lastSaved!)
                    : SingleChildScrollView(
                        controller: _scroll,
                        child: Text(
                          _transcript,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14, height: 1.25),
                        ),
                      ),
              ),
              SizedBox(
                width: double.infinity,
                height: 36,
                child: FilledButton.icon(
                  onPressed: _syncing || listening ? null : _doSync,
                  icon: const Icon(Icons.local_hospital, size: 18),
                  label: const Text('SEND TO HOSPITAL'),
                ),
              ),
            ],
          ),
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

class _SavedCard extends StatelessWidget {
  const _SavedCard({required this.row});
  final TriageRow row;

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
          Text(
            '${row.triage.toUpperCase()}  ×${row.patientCount}$age',
            style: TextStyle(
              color: triageColor(row.triage),
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            row.injuries,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14),
          ),
          Text(
            '${row.location}'
            '${row.etaMinutes != null ? ' · ETA ${row.etaMinutes} min' : ''}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: c.dim),
          ),
        ],
      ),
    );
  }
}
