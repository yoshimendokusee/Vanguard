import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_wrist/nlp/triage_parser.dart';

void main() {
  const parser = TriageParser();

  test('full pre-arrival report: count, age, injuries, location, ETA', () {
    final r = parser.parse(
      'Dalawang bata, nalunod at walang malay, sa Barangay Arnaldo, '
      'sampung minuto papunta sa ospital.',
    );
    expect(r.triage, TriageParser.immediate);
    expect(r.patientCount, 2);
    expect(r.ageGroup, 'Child');
    expect(r.injuries, ['Drowning', 'Unconscious']);
    expect(r.location, 'Barangay Arnaldo');
    expect(r.etaMinutes, 10);
    expect(r.isRecognized, isTrue);
  });

  test('delayed: fracture in an elderly patient', () {
    final r = parser.parse('lolo na nabali ang binti sa navarro, 20 minutes');
    expect(r.triage, TriageParser.delayed);
    expect(r.injuries, ['Fracture']);
    expect(r.ageGroup, 'Elderly');
    expect(r.patientCount, 1);
    expect(r.etaMinutes, 20);
    expect(r.location, 'Barangay Navarro');
  });

  test('minor: walking wounded', () {
    final r = parser.parse('tatlong tao may gasgas at nakakalakad sa santiago');
    expect(r.triage, TriageParser.minor);
    expect(r.patientCount, 3);
    expect(r.injuries, ['Abrasion', 'Ambulatory']);
  });

  test('"cannot walk" is Delayed, never Minor', () {
    final r = parser.parse('hindi makalakad, may sugat');
    expect(r.triage, TriageParser.delayed);
    expect(r.injuries, containsAll(['Non-ambulatory', 'Wound']));
    expect(r.injuries, isNot(contains('Ambulatory')));
  });

  test('specific findings hide the generic ones', () {
    final r = parser.parse('malakas na pagdurugo, dumudugo pa');
    expect(r.injuries, ['Severe bleeding']);
    expect(r.triage, TriageParser.immediate);
    expect(parser.parse('malalim na sugat').injuries, ['Laceration']);
    expect(parser.parse('maliit na sugat').injuries, ['Abrasion']);
  });

  test('each immediate trigger', () {
    for (final phrase in [
      'hindi humihinga',
      'hirap huminga',
      'nalunod',
      'walang malay',
      'nabagok',
      'masakit ang dibdib',
      'nakuryente',
      'buntis',
    ]) {
      expect(
        parser.parse('may $phrase dito').triage,
        TriageParser.immediate,
        reason: phrase,
      );
    }
  });

  test('worst finding wins; deceased never hides a live patient', () {
    expect(
      parser.parse('walang malay at may gasgas').triage,
      TriageParser.immediate,
    );
    expect(
      parser.parse('isang patay at isang sugatan').triage,
      TriageParser.delayed,
    );
  });

  test('deceased only when nothing else is found', () {
    final r = parser.parse('isang patay sa pasong kawayan');
    expect(r.triage, TriageParser.deceased);
    expect(r.location, 'Barangay Pasong Kawayan');
    expect(r.patientCount, 1);
  });

  test('ETA in hours', () {
    expect(parser.parse('sugatan, isang oras').etaMinutes, 60);
    expect(parser.parse('sugatan, kalahating oras').etaMinutes, 30);
    expect(parser.parse('sugatan').etaMinutes, isNull);
  });

  test('tolerates long-word slips but not short-word look-alikes', () {
    expect(parser.parse('nalonod sa santyago').injuries, ['Drowning']);
    expect(parser.parse('nabalik na kami').injuries, isEmpty);
  });

  test('unrecognized speech is Unassessed and flagged, not dropped', () {
    final r = parser.parse('hello kumusta po');
    expect(r.triage, TriageParser.unassessed);
    expect(r.isRecognized, isFalse);
    expect(r.rawText, 'hello kumusta po');
    expect(r.injuriesText, TriageParser.unspecified);
  });

  test('empty input', () {
    final r = parser.parse('   ');
    expect(r.isRecognized, isFalse);
    expect(r.patientCount, 1);
  });
}
