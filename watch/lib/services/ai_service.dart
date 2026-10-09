import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'hub_config.dart';

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
    available:
        json['available'] == true &&
        json['state'] == 'READY' &&
        json['inference_available'] == true,
    model: json['model'] is String ? json['model'] as String : '',
    error: json['error'] is String ? json['error'] as String : null,
  );
}

/// Allowed observation values, mirroring `hub/risk.js`.
const aiObservationValues = {
  'breathing': {'normal', 'abnormal', 'absent', 'unknown'},
  'consciousness': {'alert', 'confused', 'unresponsive', 'unknown'},
  'severeBleeding': {'present', 'absent', 'unknown'},
  'walking': {'able', 'unable', 'unknown'},
  'circulation': {'present', 'absent', 'unknown'},
};

/// Categories the deterministic hub rules can return; never Deceased.
const _provisionalTriage = {'Immediate', 'Unassessed', 'Delayed', 'Minor'};

class AiObservations {
  const AiObservations({
    required this.breathing,
    required this.consciousness,
    required this.severeBleeding,
    required this.walking,
    this.circulation = 'unknown',
  });

  final String breathing;
  final String consciousness;
  final String severeBleeding;
  final String walking;
  final String circulation;

  /// Missing keys stay unknown; out-of-schema values reject the whole reply.
  static AiObservations fromJson(Map<String, dynamic> json) {
    String value(String key) {
      final v = json[key] ?? 'unknown';
      if (v is! String || !aiObservationValues[key]!.contains(v)) {
        throw FormatException('Invalid $key observation');
      }
      return v;
    }

    return AiObservations(
      breathing: value('breathing'),
      consciousness: value('consciousness'),
      severeBleeding: value('severeBleeding'),
      walking: value('walking'),
      circulation: value('circulation'),
    );
  }
}

/// Local Qwen provenance (`processing.provenance.extraction`). Null for the
/// hub/Ollama path; never fabricated.
class AiExtractionProvenance {
  const AiExtractionProvenance({
    required this.model,
    required this.revision,
    required this.runtime,
    required this.artifactSha256,
  });

  final String model;
  final String revision;
  final String runtime;
  final String artifactSha256;
  String get execution => 'local';

  static AiExtractionProvenance? fromJson(Object? json) {
    if (json == null) return null;
    String text(String key) {
      final v = json is Map ? json[key] : null;
      if (v is! String || v.trim().isEmpty || v.length > 100) {
        throw FormatException('Invalid extraction $key');
      }
      return v;
    }

    final sha = text('artifactSha256');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
        text('execution') != 'local') {
      throw const FormatException('Extraction must be local with a SHA-256');
    }
    return AiExtractionProvenance(
      model: text('model'),
      revision: text('revision'),
      runtime: text('runtime'),
      artifactSha256: sha,
    );
  }
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
    this.extraction,
  });

  final String originalTranscript;
  final AiObservations observations;
  final Map<String, String?> evidence;
  final List<String> uncertainties;
  final List<String> warnings;
  final String provisionalTriage;
  final String provisionalReason;
  final String? draftInjuries;
  final AiExtractionProvenance? extraction;

  static AiExtraction fromJson(Map<String, dynamic> json) {
    final processing = json['processing'] as Map<String, dynamic>? ?? {};
    final obs = processing['observations'] as Map<String, dynamic>? ?? {};
    final ev = (json['evidence'] as Map<String, dynamic>?) ?? {};
    final prov = json['provisional'] as Map<String, dynamic>? ?? {};
    final draft = json['draft'] as Map<String, dynamic>?;
    final provenance = processing['provenance'] as Map<String, dynamic>? ?? {};
    // Urgency must come from the hub's deterministic rules, flagged advisory.
    if (!_provisionalTriage.contains(prov['triage']) ||
        prov['requiresVerification'] != true ||
        prov['advisoryOnly'] != true) {
      throw const FormatException('Invalid provisional triage');
    }
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
      provisionalTriage: prov['triage'] as String,
      provisionalReason: prov['reason'] as String? ?? '',
      draftInjuries: draft?['injuries'] as String?,
      extraction: AiExtractionProvenance.fromJson(provenance['extraction']),
    );
  }
}

class AiService {
  AiService({http.Client? client, String? hub, this.token = hubToken})
    : _client = client ?? http.Client(),
      _hub = hub ?? hubUrl;

  final http.Client _client;
  final String _hub;
  final String token;

  static const _timeout = Duration(seconds: 130);
  static const maxTranscript = 4000;

  Future<AiStatus> status() async {
    try {
      final res = await _client
          .get(
            hubEndpoint(_hub, '/api/ai/status'),
            headers: hubHeaders(token: token),
          )
          .timeout(const Duration(seconds: 130));
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
            hubEndpoint(_hub, '/api/ai/$kind'),
            headers: hubHeaders(token: token),
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
      final processing = decoded['processing'];
      if (processing is! Map<String, dynamic> ||
          processing['version'] != 1 ||
          processing['originalTranscript'] != transcript) {
        throw AiUnavailableException(
          'Mismatched AI reply; original stays local',
        );
      }
      return AiExtraction.fromJson(decoded);
    } on AiUnavailableException {
      rethrow;
    } on TimeoutException {
      throw AiUnavailableException('Local AI timed out; capture stays local');
    } on FormatException {
      throw AiUnavailableException(
        'Invalid AI reply rejected; capture stays local',
      );
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
