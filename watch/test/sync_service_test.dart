import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vanguard_wrist/db/triage_db.dart';
import 'package:vanguard_wrist/services/sync_service.dart';

TriageRow row(int id, {String text = 'Synthetic'}) => TriageRow(
  id: id,
  location: 'Synthetic pickup',
  injuries: 'Unspecified',
  triage: 'Unassessed',
  patientCount: 1,
  ageGroup: 'Unspecified',
  etaMinutes: null,
  rawText: text,
  createdAt: DateTime.utc(2026, 10, 9, 0, 0, id).toIso8601String(),
  synced: false,
);

http.Response ack(List<int> ids, {List<Object> rejected = const []}) =>
    http.Response(
      jsonEncode({
        'ok': true,
        'inserted': ids.length,
        'duplicates': 0,
        'rejected': rejected,
        'ackLocalIds': ids,
      }),
      200,
    );

void main() {
  test(
    'large queues are batched and only sent IDs are marked after ACK',
    () async {
      final rows = List.generate(605, (i) => row(i + 1));
      final marked = <int>[];
      var requests = 0;
      final service = SyncService(
        watchId: 'W-TEST',
        pending: () async => rows,
        acknowledge: (ids) async => marked.addAll(ids),
        client: MockClient((request) async {
          requests++;
          final reports = (jsonDecode(request.body)['reports'] as List);
          expect(reports.length, lessThanOrEqualTo(100));
          return ack(reports.map((r) => r['localId'] as int).toList());
        }),
      );
      try {
        expect((await service.sync()).ok, isTrue);
        expect(requests, 7);
        expect(marked, rows.map((r) => r.id).toList());
      } finally {
        service.dispose();
      }
    },
  );

  test(
    'unsent ACKs and malformed/contradictory replies cannot clear the queue',
    () async {
      for (final response in [
        ack([999]),
        http.Response('{"ok":false}', 200),
        ack(
          [1],
          rejected: [
            {'localId': 1, 'reason': 'invalid'},
          ],
        ),
        http.Response('invalid', 200),
      ]) {
        final marked = <int>[];
        final service = SyncService(
          watchId: 'W-TEST',
          pending: () async => [row(1)],
          acknowledge: (ids) async => marked.addAll(ids),
          client: MockClient((_) async => response),
        );
        try {
          expect((await service.sync()).ok, isFalse);
          expect(marked, isEmpty);
        } finally {
          service.dispose();
        }
      }
    },
  );

  test(
    'partial ACK marks accepted rows while rejected rows remain pending',
    () async {
      final marked = <int>[];
      final service = SyncService(
        watchId: 'W-TEST',
        pending: () async => [row(1), row(2)],
        acknowledge: (ids) async => marked.addAll(ids),
        client: MockClient(
          (_) async => ack(
            [1],
            rejected: [
              {'localId': 2, 'reason': 'invalid'},
            ],
          ),
        ),
      );
      try {
        expect((await service.sync()).ok, isFalse);
        expect(marked, [1]);
      } finally {
        service.dispose();
      }
    },
  );

  test(
    'lost response retains rows; concurrent callers share one transfer',
    () async {
      final pendingResponse = Completer<http.Response>();
      final marked = <int>[];
      var requests = 0;
      final service = SyncService(
        watchId: 'W-TEST',
        pending: () async => [row(1)],
        acknowledge: (ids) async => marked.addAll(ids),
        client: MockClient((_) async {
          requests++;
          return pendingResponse.future;
        }),
      );
      try {
        final first = service.sync();
        final second = service.sync();
        expect(identical(first, second), isTrue);
        await Future<void>.delayed(Duration.zero);
        pendingResponse.completeError(
          http.ClientException('Synthetic dropped response'),
        );
        expect((await first).ok, isFalse);
        expect(marked, isEmpty);
        expect(requests, 1);
      } finally {
        service.dispose();
      }
    },
  );

  test('long originals stay pending while other reports can sync', () async {
    var requests = 0;
    final marked = <int>[];
    final service = SyncService(
      watchId: 'W-TEST',
      pending: () async => [row(1, text: 'a' * 1001), row(2)],
      acknowledge: (ids) async => marked.addAll(ids),
      client: MockClient((request) async {
        requests++;
        expect(
          (jsonDecode(request.body)['reports'] as List).single['localId'],
          2,
        );
        return ack([2]);
      }),
    );
    try {
      expect((await service.sync()).ok, isFalse);
      expect(requests, 1);
      expect(marked, [2]);
    } finally {
      service.dispose();
    }
  });

  testWidgets('automatic retry recovers a persisted pending row without Send', (
    tester,
  ) async {
    var pending = [row(1)];
    var requests = 0;
    final service = SyncService(
      watchId: 'W-TEST',
      pending: () async => pending,
      acknowledge: (ids) async =>
          pending = pending.where((r) => !ids.contains(r.id)).toList(),
      client: MockClient((_) async {
        requests++;
        return requests == 1 ? http.Response('', 503) : ack([1]);
      }),
    );
    try {
      service.start((_) {});
      await tester.pump();
      expect(pending.length, 1);
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(pending, isEmpty);
      expect(requests, 2);
    } finally {
      service.dispose();
    }
  });
}
