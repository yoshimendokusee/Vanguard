import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../db/triage_db.dart';

/// Hospital hub address on the internet-free router. Override at build time:
///   flutter run --dart-define=HUB_URL=http://192.168.8.10:3000
const hubUrl = String.fromEnvironment(
  'HUB_URL',
  defaultValue: 'http://192.168.8.10:3000',
);

class SyncOutcome {
  const SyncOutcome.ok(this.sent, this.duplicates) : error = null;
  const SyncOutcome.failed(this.error) : sent = 0, duplicates = 0;

  final int sent;
  final int duplicates;
  final String? error;
  bool get ok => error == null;
}

class SyncService {
  SyncService(this._db, {http.Client? client})
    : _client = client ?? http.Client();

  final TriageDb _db;
  final http.Client _client;

  /// Push every unsynced report to the hospital hub. Rows are only marked
  /// synced when the hub acknowledges them, so a dropped connection just means
  /// "try again" and the hub's duplicate check makes retries safe.
  Future<SyncOutcome> sync() async {
    final rows = await _db.pending();
    if (rows.isEmpty) return const SyncOutcome.ok(0, 0);

    final body = jsonEncode({
      'watchId': _db.watchId,
      'reports': [
        for (final r in rows)
          {
            'localId': r.id,
            'location': r.location,
            'injuries': r.injuries,
            'triage': r.triage,
            'patientCount': r.patientCount,
            'ageGroup': r.ageGroup,
            'etaMinutes': r.etaMinutes,
            'rawText': r.rawText,
            'createdAt': r.createdAt,
          },
      ],
    });

    try {
      final res = await _client
          .post(
            Uri.parse('$hubUrl/api/sync-triage'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        return SyncOutcome.failed('Hub replied ${res.statusCode}');
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final acked = (json['ackLocalIds'] as List).cast<int>();
      await _db.markSynced(acked);
      return SyncOutcome.ok(
        (json['inserted'] as num).toInt(),
        (json['duplicates'] as num).toInt(),
      );
    } on TimeoutException {
      return const SyncOutcome.failed('No hospital hub on network');
    } catch (e) {
      return const SyncOutcome.failed('Hub unreachable');
    }
  }
}
