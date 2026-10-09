import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';

import 'db/triage_db.dart';
import 'nlp/triage_parser.dart';
import 'services/cloud_sync_service.dart';
import 'services/speech_service.dart';
import 'services/sync_service.dart';

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
  CloudSyncService? _cloud;

  _Phase _phase = _Phase.loading;
  String _transcript = '';
  String _status = 'LOADING MODEL…';
  TriageRow? _lastSaved;
  int _pending = 0;
  bool _syncing = false;
  int _cloudPending = 0;
  bool _cloudSyncing = false;
  bool _cloudSyncRequested = false;
  bool _cloudClaimRequested = false;
  String? _cloudError;

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
      try {
        _cloud = await CloudSyncService.initialize();
        _cloudPending = await _loadCloudPending(db);
      } catch (error) {
        _cloudError = error.toString();
      }
      await _speech.init();
      setState(() {
        _phase = _Phase.idle;
        _status = 'TAP TO REPORT';
      });
      if (_cloud?.currentUser != null) {
        unawaited(_syncCloud());
      }
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
    final row = await _db!.insert(
      result,
      cloudOwnerId: _cloud?.currentUser?.id,
    );
    final pending = await _db!.pendingCount();
    final cloudPending = await _loadCloudPending(_db!);
    await _buzz(!result.isRecognized
        ? _Buzz.unrecognized
        : result.triage == TriageParser.immediate
            ? _Buzz.immediate
            : _Buzz.saved);
    setState(() {
      _phase = _Phase.idle;
      _lastSaved = row;
      _pending = pending;
      _cloudPending = cloudPending;
      _status = result.isRecognized ? 'SAVED' : 'SAVED – CHECK';
    });
    if (_cloud?.currentUser != null) {
      unawaited(_syncCloud());
    }
  }

  /// Demo fail-safe: long-press the header to run a sample report through the
  /// full parse/save pipeline without using the microphone.
  Future<void> _demoPhrase() async {
    if (_phase != _Phase.idle) return;
    const phrase = 'Dalawang bata, nalunod at walang malay, sa Barangay '
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

  Future<void> _syncCloud({bool confirmUnassigned = false}) async {
    final cloud = _cloud;
    final db = _db;
    if (cloud == null || db == null) return;
    if (_cloudSyncing) {
      _cloudSyncRequested = true;
      _cloudClaimRequested |= confirmUnassigned;
      return;
    }
    if (!cloud.configured) {
      setState(() => _cloudError =
          cloud.configurationMessage ?? 'Supabase is not configured');
      return;
    }
    final user = cloud.currentUser;
    if (user == null) {
      setState(() => _cloudError = 'Sign in to sync cloud reports');
      return;
    }

    setState(() {
      _cloudSyncing = true;
      _cloudError = null;
    });
    try {
      final unassigned = await db.unassignedCloudCount();
      if (confirmUnassigned && unassigned > 0) {
        final confirmed = await _confirmUnassignedReports(unassigned);
        if (confirmed) await db.claimUnassignedCloudRows(user.id);
      }
      final sent = await cloud.syncPending(db);
      _cloudPending = await _loadCloudPending(db);
      setState(() {
        _status = sent == 0 ? 'NO CLOUD REPORTS TO SEND' : 'CLOUD SENT $sent';
      });
    } catch (error) {
      if (mounted) setState(() => _cloudError = error.toString());
    } finally {
      try {
        _cloudPending = await _loadCloudPending(db);
      } catch (error) {
        if (mounted) setState(() => _cloudError = error.toString());
      }
      if (mounted) setState(() => _cloudSyncing = false);
      if (_cloudSyncRequested && mounted) {
        final confirm = _cloudClaimRequested;
        _cloudSyncRequested = false;
        _cloudClaimRequested = false;
        unawaited(_syncCloud(confirmUnassigned: confirm));
      }
    }
  }

  Future<int> _loadCloudPending(TriageDb db) async {
    final userId = _cloud?.currentUser?.id;
    if (userId == null) return db.pendingCloudCount();
    final owned = await db.pendingCloudCount(userId: userId);
    final unassigned = await db.unassignedCloudCount();
    return owned + unassigned;
  }

  Future<bool> _confirmUnassignedReports(int count) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Assign local reports?'),
          content: Text(
            '$count reports saved while signed out or before cloud sync was '
            'configured will be assigned to the signed-in account and uploaded.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('KEEP LOCAL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ASSIGN & UPLOAD'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _manageCloudAccount() async {
    final cloud = _cloud;
    if (cloud == null || !cloud.configured) {
      setState(() => _cloudError = _cloudError ??
          cloud?.configurationMessage ??
          'Supabase is not configured');
      return;
    }

    final currentUser = cloud.currentUser;
    if (currentUser != null) {
      final signOut = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Cloud account'),
              content: Text('Signed in as ${currentUser.email ?? currentUser.id}'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('CANCEL'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('SIGN OUT'),
                ),
              ],
            ),
          ) ??
          false;
      if (signOut) {
        try {
          await cloud.signOut();
          if (mounted) {
            final db = _db;
            if (db != null) _cloudPending = await _loadCloudPending(db);
            setState(() => _cloudError = null);
          }
        } catch (error) {
          if (mounted) setState(() => _cloudError = error.toString());
        }
      }
      return;
    }

    final email = TextEditingController();
    final password = TextEditingController();
    var creatingAccount = false;
    var busy = false;
    String? dialogError;
    final signedIn = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(creatingAccount ? 'Create cloud account' : 'Cloud sign in'),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                if (dialogError != null) ...[
                  const SizedBox(height: 8),
                  Text(dialogError!, style: const TextStyle(color: Colors.redAccent)),
                ],
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setDialogState(
                            () => creatingAccount = !creatingAccount,
                          ),
                  child: Text(creatingAccount
                      ? 'Already have an account? Sign in'
                      : 'Create an account'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  busy ? null : () => Navigator.pop(dialogContext, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() {
                        busy = true;
                        dialogError = null;
                      });
                      try {
                        if (creatingAccount) {
                          final hasSession = await cloud.signUp(
                            email.text.trim(),
                            password.text,
                          );
                          if (!hasSession) {
                            setDialogState(() {
                              busy = false;
                              dialogError =
                                  'Check your email to confirm, then sign in.';
                            });
                            return;
                          }
                        } else {
                          await cloud.signIn(email.text.trim(), password.text);
                        }
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, true);
                        }
                      } catch (error) {
                        setDialogState(() {
                          busy = false;
                          dialogError = error.toString();
                        });
                      }
                    },
              child: Text(creatingAccount ? 'CREATE' : 'SIGN IN'),
            ),
          ],
        ),
      ),
    );
    email.dispose();
    password.dispose();

    if (signedIn == true && mounted) {
      setState(() => _cloudError = null);
      await _syncCloud(confirmUnassigned: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listening = _phase == _Phase.listening;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onLongPress: _demoPhrase,
                      child: Text(
                        '${_db?.watchId ?? '…'}  ·  $_pending HOSPITAL',
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            letterSpacing: 1),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _cloud?.currentUser?.email ??
                        _cloudError ??
                        'Cloud account',
                    onPressed: _manageCloudAccount,
                    icon: Icon(
                      _cloud?.currentUser == null
                          ? Icons.cloud_off_outlined
                          : Icons.cloud_done_outlined,
                      color: _cloud?.currentUser == null
                          ? Colors.white70
                          : const Color(0xFF00E676),
                    ),
                  ),
                ],
              ),
              Text(
                '$_cloudPending CLOUD PENDING'
                '${_cloudSyncing ? ' · SYNCING' : ''}',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 9, letterSpacing: 1),
              ),
              if (_cloudError != null)
                Text(
                  _cloudError!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 9),
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
                            // Idle is cyan on purpose: red/yellow/green mean
                            // triage categories on this screen.
                            color: listening
                                ? const Color(0xFFFF1744)
                                : _phase == _Phase.idle
                                    ? const Color(0xFF00E5FF)
                                    : Colors.grey.shade800,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          child: Icon(
                            listening ? Icons.stop_rounded : Icons.mic_rounded,
                            size: 64,
                            color: listening ? Colors.white : Colors.black,
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
                    fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1),
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
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: FilledButton.icon(
                        onPressed: _syncing || listening ? null : _doSync,
                        icon: const Icon(Icons.local_hospital, size: 15),
                        label: const Text(
                          'HOSPITAL',
                          style: TextStyle(fontSize: 10),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: FilledButton.icon(
                        onPressed:
                            _cloudSyncing || listening ? null : () => _syncCloud(confirmUnassigned: true),
                        icon: const Icon(Icons.cloud_upload_outlined, size: 15),
                        label: const Text(
                          'ONLINE',
                          style: TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                  ),
                ],
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
                fontWeight: FontWeight.w900),
          ),
          Text(row.injuries,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
          Text(
            '${row.location}'
            '${row.etaMinutes != null ? ' · ETA ${row.etaMinutes} min' : ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
