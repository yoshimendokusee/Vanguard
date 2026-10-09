import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_wrist/db/triage_db.dart';
import 'package:vanguard_wrist/services/cloud_sync_service.dart';

String _syntheticJwt(Map<String, Object> claims) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.sig';

void main() {
  test(
    'missing, non-HTTPS or secret Supabase values disable cloud sync only',
    () {
      expect(cloudConfigurationError('', ''), 'Cloud sync is not configured');
      expect(
        cloudConfigurationError('https://example.supabase.co', ''),
        'Cloud sync is not configured',
      );
      expect(
        cloudConfigurationError('', 'sb_publishable_synthetic'),
        'Cloud sync is not configured',
      );
      for (final url in [
        'http://example.supabase.co',
        'example.supabase.co',
        'https://',
        'ftp://example.supabase.co',
      ]) {
        expect(
          cloudConfigurationError(url, 'sb_publishable_synthetic'),
          'SUPABASE_URL must use HTTPS',
        );
      }
      for (final key in [
        'sb_secret_synthetic',
        _syntheticJwt({'role': 'service_role'}),
      ]) {
        expect(
          cloudConfigurationError('https://example.supabase.co', key),
          contains('not a secret key'),
        );
      }
      for (final key in [
        'sb_publishable_synthetic',
        _syntheticJwt({'role': 'anon'}),
      ]) {
        expect(
          cloudConfigurationError('https://example.supabase.co', key),
          isNull,
        );
      }
    },
  );

  test('cloud payload preserves the stable ID and SQLite report fields', () {
    final row = TriageRow.fromMap({
      'id': 7,
      'location': 'Barangay Arnaldo',
      'injuries': 'Drowning, Unconscious',
      'triage': 'Immediate',
      'patient_count': 2,
      'age_group': 'Child',
      'eta_minutes': 10,
      'raw_text': 'Synthetic test transcript',
      'created_at': '2026-10-09T06:00:00.123Z',
      'sync_status': 0,
      'report_id': 'c88ac7af-fca3-42c2-bdd9-d3ec96ae1786',
      'cloud_owner_id': '5fd05392-6cf6-4d7e-8743-dd6e2f16fd93',
      'cloud_sync_status': 0,
    });

    expect(cloudReportPayload(row, 'W-TEST'), {
      'report_id': 'c88ac7af-fca3-42c2-bdd9-d3ec96ae1786',
      'watch_id': 'W-TEST',
      'location': 'Barangay Arnaldo',
      'injuries': 'Drowning, Unconscious',
      'triage': 'Immediate',
      'patient_count': 2,
      'age_group': 'Child',
      'eta_minutes': 10,
      'raw_text': 'Synthetic test transcript',
      'created_at': '2026-10-09T06:00:00.123Z',
    });
  });
}
