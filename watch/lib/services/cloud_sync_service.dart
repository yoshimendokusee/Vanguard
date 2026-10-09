import 'package:supabase_flutter/supabase_flutter.dart';

import '../db/triage_db.dart';

Map<String, Object?> cloudReportPayload(TriageRow row, String watchId) => {
  'report_id': row.reportId,
  'watch_id': watchId,
  'location': row.location,
  'injuries': row.injuries,
  'triage': row.triage,
  'patient_count': row.patientCount,
  'age_group': row.ageGroup,
  'eta_minutes': row.etaMinutes,
  'raw_text': row.rawText,
  'created_at': row.createdAt,
};

class CloudSyncService {
  static const _batchSize = 100;

  CloudSyncService._(this._client, this.configurationMessage);

  static const _url = String.fromEnvironment('SUPABASE_URL');
  static const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  final SupabaseClient? _client;
  final String? configurationMessage;

  static Future<CloudSyncService> initialize() async {
    if (_url.isEmpty || _anonKey.isEmpty) {
      return CloudSyncService._(null, 'Cloud sync is not configured');
    }
    final projectUri = Uri.tryParse(_url);
    if (projectUri == null ||
        projectUri.scheme != 'https' ||
        projectUri.host.isEmpty) {
      throw const FormatException('SUPABASE_URL must use HTTPS');
    }

    await Supabase.initialize(url: _url, publishableKey: _anonKey);
    return CloudSyncService._(Supabase.instance.client, null);
  }

  bool get configured => _client != null;
  User? get currentUser => _client?.auth.currentUser;

  Future<void> signIn(String email, String password) async {
    await _requireClient().auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  Future<bool> signUp(String email, String password) async {
    final response = await _requireClient().auth.signUp(
      email: email,
      password: password,
    );
    return response.session != null;
  }

  Future<void> signOut() => _requireClient().auth.signOut();

  Future<int> syncPending(TriageDb db) async {
    final client = _requireClient();
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Sign in to sync reports to Supabase');
    }

    final rows = await db.pendingCloud(userId);
    if (rows.isEmpty) return 0;

    var syncedCount = 0;
    for (var start = 0; start < rows.length; start += _batchSize) {
      final batch = rows.skip(start).take(_batchSize).toList();
      final response = await client
          .from('triage_reports')
          .upsert([
            for (final row in batch) cloudReportPayload(row, db.watchId),
          ], onConflict: 'report_id')
          .select('report_id');

      final acknowledgedIds = response
          .map((record) => record['report_id'] as String)
          .toSet();
      await db.markCloudSynced(acknowledgedIds, userId: userId);
      if (acknowledgedIds.length != batch.length) {
        throw StateError(
          'Supabase acknowledged ${acknowledgedIds.length} '
          'of ${batch.length} reports in a batch',
        );
      }
      syncedCount += acknowledgedIds.length;
    }
    return syncedCount;
  }

  SupabaseClient _requireClient() {
    final client = _client;
    if (client == null) {
      throw StateError(configurationMessage ?? 'Supabase is not configured');
    }
    return client;
  }
}
