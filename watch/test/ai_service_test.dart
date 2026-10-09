import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vanguard_wrist/services/ai_service.dart';

const transcript =
    'Synthetic patient is awake, breathing normally, no severe bleeding, can walk.';

http.Response okExtract() => http.Response(
  jsonEncode({
    'ok': true,
    'processing': {
      'version': 1,
      'originalTranscript': transcript,
      'observations': {
        'breathing': 'normal',
        'consciousness': 'alert',
        'severeBleeding': 'absent',
        'walking': 'able',
      },
      'uncertainties': [
        'Extracted observations require qualified verification',
      ],
      'provenance': {
        'device': 'wear-os',
        'sttEngine': 'device-stt',
        'sttRuntime': 'hub-ai-v1',
        'extraction': null,
      },
    },
    'evidence': {
      'breathing': 'breathing normally',
      'consciousness': 'awake',
      'severeBleeding': 'no severe bleeding',
      'walking': 'can walk',
    },
    'warnings': [],
    'provisional': {
      'triage': 'Minor',
      'reason': 'Walking, alert, normal breathing, no severe bleeding reported',
      'version': 'provisional-v1',
      'requiresVerification': true,
      'advisoryOnly': true,
    },
    'model': 'qwen3:0.6b',
    'promptVersion': 'vanguard-extract-v1',
  }),
  200,
);

AiService service(Future<http.Response> Function(http.BaseRequest) fn) =>
    AiService(client: MockClient(fn), hub: 'http://hub.test');

void main() {
  test(
    'model tag alone and mismatched replies do not establish readiness',
    () async {
      final tag = service(
        (_) async => http.Response('{"ok":true,"available":true}', 200),
      );
      final wrong = service(
        (_) async => http.Response(
          '{"ok":true,"processing":{"version":1,"originalTranscript":"different"}}',
          200,
        ),
      );
      try {
        expect((await tag.status()).available, isFalse);
        expect(
          () => wrong.extract(transcript),
          throwsA(isA<AiUnavailableException>()),
        );
      } finally {
        tag.dispose();
        wrong.dispose();
      }
    },
  );
  test('status reports hub availability without blocking capture', () async {
    final up = service(
      (_) async => http.Response(
        jsonEncode({
          'ok': true,
          'available': true,
          'state': 'READY',
          'inference_available': true,
          'model': 'qwen3:0.6b',
        }),
        200,
      ),
    );
    try {
      final s = await up.status();
      expect(s.available, isTrue);
      expect(s.model, 'qwen3:0.6b');
    } finally {
      up.dispose();
    }

    final down = service((_) async => http.Response('', 503));
    try {
      expect(() => down.status(), throwsA(isA<AiUnavailableException>()));
    } finally {
      down.dispose();
    }
  });

  test(
    'extract returns observations, evidence and provisional triage',
    () async {
      final ai = service((_) async => okExtract());
      try {
        final out = await ai.extract(transcript);
        expect(out.originalTranscript, transcript);
        expect(out.observations.breathing, 'normal');
        expect(out.observations.consciousness, 'alert');
        expect(out.evidence['breathing'], 'breathing normally');
        expect(out.warnings, isEmpty);
        expect(out.provisionalTriage, 'Minor');
        expect(out.provisionalReason, contains('Walking'));
      } finally {
        ai.dispose();
      }
    },
  );

  test('triage-assist exposes the reviewable draft injuries', () async {
    final body = jsonDecode(okExtract().body) as Map<String, dynamic>;
    body['draft'] = {
      'injuries': 'Ambulatory',
      'triage': 'Minor',
      'provisional': true,
    };
    final ai = service((_) async => http.Response(jsonEncode(body), 200));
    try {
      final out = await ai.triageAssist(transcript);
      expect(out.draftInjuries, 'Ambulatory');
      expect(out.provisionalTriage, 'Minor');
    } finally {
      ai.dispose();
    }
  });

  test('empty and oversized transcripts never reach the hub', () async {
    var requests = 0;
    final ai = service((_) async {
      requests++;
      return okExtract();
    });
    try {
      expect(() => ai.extract('   '), throwsArgumentError);
      expect(() => ai.extract('a' * 4001), throwsArgumentError);
      expect(requests, 0);
    } finally {
      ai.dispose();
    }
  });

  test('hub AI failure keeps the report local with a clear error', () async {
    final ai = service(
      (_) async => http.Response(
        jsonEncode({
          'ok': false,
          'error': 'ollama-unreachable',
          'message': 'Local AI is unreachable',
        }),
        503,
      ),
    );
    try {
      expect(
        () => ai.extract(transcript),
        throwsA(
          isA<AiUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('unreachable'),
          ),
        ),
      );
    } finally {
      ai.dispose();
    }
  });
}
