import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync_service.dart' show hubUrl;

/// Local AI (Qwen via the hospital hub) for the watch.
///
/// The watch never talks to Ollama directly: it POSTs a transcript to the
/// hub's `/api/ai/*` endpoints and gets back validated observations. When the
/// hub is unreachable the call fails fast with [AiUnavailableException] and
/// the caller must keep the report in local SQLite — capture never waits on AI.
class AiUnavailableException implements Exception {
  AiUnavailableException(this.message);
  final String message;
  @override
  String toString() => 'AiUnavailableException: $message';
}

class AiStatus {
  const AiStatus({required this.available, required this.model, this.error});

  final bool available;
  final String model;
  final String? error;

  static AiStatus fromJson(Map<String, dynamic> json) => AiStatus(
    available: json['available'] == true,
    model: json['model'] is String ? json['model'] as String : '',
    error: json['error'] is String ? json['error'] as String : null,
  );
}

class AiObservations {
  const AiObservations({
    required this.breathing,
    required this.consciousness,
    required this.severeBleeding,
    required this.walking,
  });

  final String breathing;
  final String consciousness;
  final String severeBleeding;
  final String walking;

  static AiObservations fromJson(Map<String, dynamic> json) => AiObservations(
    breathing: json['breathing'] as String? ?? 'unknown',
    consciousness: json['consciousness'] as String? ?? 'unknown',
    severeBleeding: json['severeBleeding'] as String? ?? 'unknown',
    walking: json['walking'] as String? ?? 'unknown',
  );
}

class AiExtraction {
  const AiExtraction({
    required this.originalTranscript,
    required this.observations,
    required this.evidence,
    required this.uncertainties,
    required this.warnings,
    required this.provisionalTriage,
    required this.provisionalReason,
    this.draftInjuries,
  });

  final String originalTranscript;
  final AiObservations observations;
  final Map<String, String?> evidence;
  final List<String> uncertainties;
  final List<String> warnings;
  final String provisionalTriage;
  final String provisionalReason;
  final String? draftInjuries;

  static AiExtraction fromJson(Map<String, dynamic> json) {
    final processing = json['processing'] as Map<String, dynamic>? ?? {};
    final obs = processing['observations'] as Map<String, dynamic>? ?? {};
    final ev = (json['evidence'] as Map<String, dynamic>?) ?? {};
    final prov = json['provisional'] as Map<String, dynamic>? ?? {};
    final draft = json['draft'] as Map<String, dynamic>?;
    return AiExtraction(
      originalTranscript: processing['originalTranscript'] as String? ?? '',
      observations: AiObservations.fromJson(obs),
      evidence: {
        for (final k in [
          'breathing',
          'consciousness',
          'severeBleeding',
          'walking',
        ])
          k: ev[k] is String ? ev[k] as String : null,
      },
      uncertainties: [
        for (final u in (processing['uncertainties'] as List? ?? []))
          if (u is String) u,
      ],
      warnings: [
        for (final w in (json['warnings'] as List? ?? []))
          if (w is String) w,
      ],
      provisionalTriage: prov['triage'] as String? ?? 'Unassessed',
      provisionalReason: prov['reason'] as String? ?? '',
      draftInjuries: draft?['injuries'] as String?,
    );
  }
}

class AiService {
  AiService({http.Client? client, String? hub})
    : _client = client ?? http.Client(),
      _hub = hub ?? hubUrl;

  final http.Client _client;
  final String _hub;

  static const _timeout = Duration(seconds: 30);
  static const maxTranscript = 4000;

  Future<AiStatus> status() async {
    try {
      final res = await _client
          .get(Uri.parse('$_hub/api/ai/status'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        throw AiUnavailableException('Hub replied ${res.statusCode}');
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        throw AiUnavailableException('Invalid AI status reply');
      }
      return AiStatus.fromJson(decoded);
    } on AiUnavailableException {
      rethrow;
    } on TimeoutException {
      throw AiUnavailableException('No hospital hub on network');
    } catch (_) {
      throw AiUnavailableException('AI unavailable; capture stays local');
    }
  }

  Future<AiExtraction> extract(String transcript, {String device = 'wear-os'}) {
    return _post('extract', transcript, device);
  }

  Future<AiExtraction> triageAssist(
    String transcript, {
    String device = 'wear-os',
  }) {
    return _post('triage-assist', transcript, device);
  }

  Future<AiExtraction> _post(
    String kind,
    String transcript,
    String device,
  ) async {
    if (transcript.trim().isEmpty) {
      throw ArgumentError('transcript must be non-empty');
    }
    if (transcript.length > maxTranscript) {
      throw ArgumentError('transcript exceeds $maxTranscript characters');
    }
    try {
      final res = await _client
          .post(
            Uri.parse('$_hub/api/ai/$kind'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'transcript': transcript, 'device': device}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        throw AiUnavailableException(
          _serverMessage(res.body) ?? 'Hub replied ${res.statusCode}',
        );
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
        throw AiUnavailableException(
          _serverMessage(res.body) ?? 'Invalid AI reply',
        );
      }
      return AiExtraction.fromJson(decoded);
    } on AiUnavailableException {
      rethrow;
    } on TimeoutException {
      throw AiUnavailableException('Local AI timed out; capture stays local');
    } catch (_) {
      throw AiUnavailableException('AI unavailable; capture stays local');
    }
  }

  String? _serverMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        const messages = {
          'ollama-unreachable': 'Local AI is unreachable',
          'ollama-timeout': 'Local AI timed out',
          'model-missing': 'Qwen model is missing on the hub computer',
        };
        final code = decoded['error'];
        if (code is String && messages.containsKey(code)) return messages[code];
        if (decoded['message'] is String) return decoded['message'] as String;
      }
    } catch (_) {}
    return null;
  }

  void dispose() => _client.close();
}
