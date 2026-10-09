import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../db/triage_db.dart';
import 'hub_config.dart';
export 'hub_config.dart' show hubUrl;

class SyncOutcome {
  const SyncOutcome.ok(this.sent, this.duplicates) : error = null;
  const SyncOutcome.failed(this.error) : sent = 0, duplicates = 0;

  final int sent;
  final int duplicates;
  final String? error;
  bool get ok => error == null;
}

class SyncService {
  SyncService({
    required this.watchId,
    required this.pending,
    required this.acknowledge,
    http.Client? client,
    this.hub = hubUrl,
    this.token = hubToken,
  }) : _client = client ?? http.Client();

  final String watchId;
  final Future<List<TriageRow>> Function() pending;
  final Future<void> Function(Iterable<int>) acknowledge;
  final http.Client _client;
  final String hub;
  final String token;
  Future<SyncOutcome>? _inFlight;
  Timer? _retry;
  void Function(SyncOutcome)? _onOutcome;
  int _failures = 0;
  bool _closed = false;

  /// Foreground retries only. SQLite remains the queue across app restarts.
  void start(void Function(SyncOutcome) onOutcome) {
    _onOutcome = onOutcome;
    unawaited(sync());
  }

  Future<SyncOutcome> sync() {
    if (_closed) return Future.value(const SyncOutcome.failed('Sync stopped'));
    return _inFlight ??= _run();
  }

  Future<SyncOutcome> _run() async {
    _retry?.cancel();
    final outcome = await _sendPending();
    _inFlight = null;
    if (!_closed) {
      _failures = outcome.ok ? 0 : (_failures + 1).clamp(0, 4);
      _onOutcome?.call(outcome);
      if (_onOutcome != null) {
        _retry = Timer(Duration(seconds: 30 * (1 << _failures)), () {
          unawaited(sync());
        });
      }
    }
    return outcome;
  }

  Future<SyncOutcome> _sendPending() async {
    try {
      final pendingRows = await pending();
      // Reject oversize originals locally while other reports can proceed.
      final rows = pendingRows.where((r) => r.rawText.length <= 16000).toList();
      final longOriginals = rows.length != pendingRows.length;
      var inserted = 0;
      var duplicates = 0;
      var incomplete = false;
      for (var offset = 0; offset < rows.length;) {
        final batch = <TriageRow>[];
        final wireReports = <Map<String, Object?>>[];
        var bytes = utf8
            .encode(jsonEncode({'watchId': watchId, 'reports': []}))
            .length;
        while (offset < rows.length && batch.length < 100) {
          final r = rows[offset];
          final wire = <String, Object?>{
            'localId': r.id,
            'location': r.location,
            'injuries': r.injuries,
            'triage': r.triage,
            'patientCount': r.patientCount,
            'ageGroup': r.ageGroup,
            'etaMinutes': r.etaMinutes,
            'rawText': r.rawText,
            'createdAt': r.createdAt,
          };
          final size =
              utf8.encode(jsonEncode(wire)).length + (batch.isEmpty ? 0 : 1);
          if (bytes + size > 900 * 1024) break;
          bytes += size;
          batch.add(r);
          wireReports.add(wire);
          offset++;
        }
        if (batch.isEmpty) {
          return const SyncOutcome.failed('Report exceeds transport limit');
        }
        final body = jsonEncode({'watchId': watchId, 'reports': wireReports});
        final res = await _client
            .post(
              hubEndpoint(hub, '/api/sync-triage'),
              headers: hubHeaders(token: token),
              body: body,
            )
            .timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) {
          return SyncOutcome.failed('Hub replied ${res.statusCode}');
        }
        final response = jsonDecode(res.body);
        if (response is! Map<String, dynamic> ||
            response['ok'] != true ||
            response['ackLocalIds'] is! List ||
            response['rejected'] is! List ||
            response['inserted'] is! int ||
            response['duplicates'] is! int ||
            response['inserted'] < 0 ||
            response['duplicates'] < 0) {
          return const SyncOutcome.failed('Invalid hospital acknowledgment');
        }
        final sentIds = batch.map((r) => r.id).toSet();
        final acked = response['ackLocalIds'] as List;
        if (acked.any((id) => id is! int || !sentIds.contains(id)) ||
            response['rejected'].any(
              (r) => r is! Map || acked.contains(r['localId']),
            )) {
          return const SyncOutcome.failed('Invalid hospital acknowledgment');
        }
        if (_closed) return const SyncOutcome.failed('Sync stopped');
        await acknowledge(acked.cast<int>().toSet());
        inserted += response['inserted'] as int;
        duplicates += response['duplicates'] as int;
        incomplete |= acked.toSet().length != batch.length;
      }
      if (longOriginals) {
        return const SyncOutcome.failed(
          'Transcript exceeds 16000 characters; retained locally',
        );
      }
      return incomplete
          ? const SyncOutcome.failed(
              'Some reports remain pending; check rejection',
            )
          : SyncOutcome.ok(inserted, duplicates);
    } on TimeoutException {
      return const SyncOutcome.failed('No hospital hub on network');
    } catch (_) {
      return const SyncOutcome.failed('Sync failed; reports remain pending');
    }
  }

  void dispose() {
    _closed = true;
    _retry?.cancel();
    _client.close();
  }
}
