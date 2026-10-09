/// Deterministic Taglish medical-triage extractor: keyword maps + fuzzy match,
/// no model, no network.
///
/// Turns the raw Vosk string into what an emergency department needs before a
/// casualty arrives: how many patients, how old, what's wrong, how urgent
/// (START category), where from, and when they'll arrive.
///
/// This is decision SUPPORT for a rescuer's spoken report, not a diagnosis.
/// When in doubt it over-triages (e.g. any head injury is Immediate) and it
/// never discards speech it can't understand (it saves it as "Unassessed").
library;

class TriageResult {
  const TriageResult({
    required this.location,
    required this.injuries,
    required this.triage,
    required this.patientCount,
    required this.ageGroup,
    required this.etaMinutes,
    required this.rawText,
  });

  final String location;
  final List<String> injuries;

  /// START category: Immediate / Delayed / Minor / Deceased, or Unassessed.
  final String triage;
  final int patientCount;
  final String ageGroup;

  /// Minutes from the moment of the report until arrival, if the rescuer said.
  final int? etaMinutes;
  final String rawText;

  bool get hasLocation => location != TriageParser.unknownLocation;

  /// True when at least one medical keyword was understood. Unrecognized
  /// reports are still saved but get a different haptic pattern, so the
  /// rescuer knows to repeat or verify.
  bool get isRecognized => injuries.isNotEmpty;

  String get injuriesText =>
      injuries.isEmpty ? TriageParser.unspecified : injuries.join(', ');

  @override
  String toString() =>
      'TriageResult($triage ×$patientCount $ageGroup, '
      '$injuriesText, $location, eta: $etaMinutes)';
}

enum _Tier { immediate, delayed, minor, deceased }

class _Injury {
  const _Injury(
    this.name,
    this.tier,
    this.variants, {
    this.supersedes = const [],
  });
  final String name;
  final _Tier tier;
  final List<String> variants;

  /// More specific findings hide the generic ones they contain
  /// ("severe bleeding" shouldn't also list "bleeding").
  final List<String> supersedes;
}

class TriageParser {
  const TriageParser();

  static const immediate = 'Immediate';
  static const delayed = 'Delayed';
  static const minor = 'Minor';
  static const deceased = 'Deceased';
  static const unassessed = 'Unassessed';

  static const unknownLocation = 'Unknown';
  static const unspecified = 'Unspecified';

  /// Pickup locations.
  static const Map<String, List<String>> locations = {
    'Arnaldo': ['arnaldo'],
    'Navarro': ['navarro'],
    'Santiago': ['santiago'],
    'Pasong Kawayan': ['pasong kawayan'],
  };

  // Variants are lowercase, punctuation-free ("can't" tokenizes to "can t").
  static const List<_Injury> _injuries = [
    // --- Immediate (red): airway, breathing, circulation, consciousness ------
    _Injury('Not breathing', _Tier.immediate, [
      'hindi humihinga',
      'di humihinga',
      'not breathing',
      'walang hininga',
      'wala nang hininga',
      'walang pulso',
      'no pulse',
    ]),
    _Injury('Difficulty breathing', _Tier.immediate, [
      'hirap huminga',
      'nahihirapan huminga',
      'mahirap huminga',
      'hirap sa paghinga',
      'hinihingal',
      'hindi makahinga',
      'di makahinga',
      'kinakapos ng hininga',
      'kinakapos sa hininga',
      'kapos hininga',
      'difficulty breathing',
      'shortness of breath',
      'can t breathe',
      'cant breathe',
      'cannot breathe',
      'unable to breathe',
    ]),
    _Injury('Drowning', _Tier.immediate, [
      'nalunod',
      'nalulunod',
      'lunod',
      'drowning',
      'drowned',
    ]),
    _Injury('Unconscious', _Tier.immediate, [
      'walang malay',
      'nawalan ng malay',
      'walang ulirat',
      'nawalan ng ulirat',
      'hindi sumasagot',
      'di sumasagot',
      'unconscious',
      'unresponsive',
    ]),
    _Injury(
      'Severe bleeding',
      _Tier.immediate,
      [
        'malakas na pagdurugo',
        'maraming dugo',
        'sobrang dugo',
        'duguan',
        'severe bleeding',
        'massive bleeding',
        'heavy bleeding',
        'profuse bleeding',
        'hemorrhage',
      ],
      supersedes: ['Bleeding'],
    ),
    _Injury(
      'Head injury',
      _Tier.immediate,
      [
        'nabagok',
        'sugat sa ulo',
        'bukas ang ulo',
        'head injury',
        'head trauma',
      ],
      supersedes: ['Wound'],
    ),
    _Injury('Chest pain', _Tier.immediate, [
      'masakit ang dibdib',
      'sakit sa dibdib',
      'atake sa puso',
      'chest pain',
      'heart attack',
    ]),
    _Injury('Electrocution', _Tier.immediate, [
      'nakuryente',
      'kuryente',
      'electrocuted',
      'electrocution',
    ]),
    _Injury('Pregnant / labor', _Tier.immediate, [
      'buntis',
      'manganganak',
      'nanganganak',
      'pregnant',
      'labor',
    ]),

    // --- Delayed (yellow): serious but can wait --------------------------------
    _Injury('Fracture', _Tier.delayed, [
      'nabali',
      'bali',
      'baling buto',
      'fracture',
      'fractured',
      'broken bone',
      'broken leg',
      'broken arm',
    ]),
    _Injury(
      'Laceration',
      _Tier.delayed,
      [
        'malalim na sugat',
        'nahiwa',
        'hiwa',
        'laceration',
        'deep cut',
        'deep wound',
      ],
      supersedes: ['Wound'],
    ),
    _Injury('Bleeding', _Tier.delayed, ['dumudugo', 'pagdurugo', 'bleeding']),
    _Injury('Wound', _Tier.delayed, [
      'sugat',
      'sugatan',
      'nasugatan',
      'wound',
      'wounded',
      'injured',
    ]),
    _Injury('Hypothermia', _Tier.delayed, [
      'hypothermia',
      'nilalamig',
      'giniginaw',
      'nanginginig',
    ]),
    _Injury('Burn', _Tier.delayed, [
      'napaso',
      'nasunog',
      'paso',
      'burn',
      'burns',
      'burned',
    ]),
    _Injury('Snakebite', _Tier.delayed, [
      'tinuklaw',
      'tuklaw',
      'ahas',
      'snakebite',
      'snake bite',
    ]),
    _Injury('Weak / dehydrated', _Tier.delayed, [
      'nanghihina',
      'mahina',
      'dehydrated',
      'weak',
    ]),
    _Injury(
      'Non-ambulatory',
      _Tier.delayed,
      [
        'hindi makalakad',
        'di makalakad',
        'hindi nakakalakad',
        'di nakakalakad',
        'cannot walk',
        'can t walk',
        'cant walk',
        'could not walk',
        'cannot stand',
        'unable to walk',
      ],
      supersedes: ['Ambulatory'],
    ),

    // --- Minor (green): walking wounded ----------------------------------------
    _Injury(
      'Abrasion',
      _Tier.minor,
      [
        'gasgas',
        'galos',
        'maliit na sugat',
        'minor cut',
        'abrasion',
        'scratch',
        'scratches',
        'minor',
      ],
      supersedes: ['Wound', 'Bleeding'],
    ),
    _Injury('Ambulatory', _Tier.minor, [
      'nakakalakad',
      'makalakad',
      'kayang maglakad',
      'nakakatayo',
      'can walk',
      'able to walk',
      'walking',
    ]),

    // --- Deceased (black): lowest precedence, never hides a live patient ---------
    _Injury('Deceased', _Tier.deceased, [
      'wala nang buhay',
      'namatay',
      'patay',
      'deceased',
      'dead',
    ]),
  ];

  static const Map<String, List<String>> _ageGroups = {
    'Infant': ['sanggol', 'baby', 'babies', 'infant'],
    'Child': ['bata', 'anak', 'paslit', 'child', 'children', 'kid', 'kids'],
    'Elderly': ['lolo', 'lola', 'matanda', 'elderly', 'senior'],
    'Adult': ['adult', 'adults'],
  };

  static const Map<String, int> _numberWords = {
    'isa': 1,
    'isang': 1,
    'one': 1,
    'dalawa': 2,
    'dalawang': 2,
    'two': 2,
    'tatlo': 3,
    'tatlong': 3,
    'three': 3,
    'apat': 4,
    'four': 4,
    'lima': 5,
    'limang': 5,
    'five': 5,
    'anim': 6,
    'six': 6,
    'pito': 7,
    'pitong': 7,
    'seven': 7,
    'walo': 8,
    'walong': 8,
    'eight': 8,
    'siyam': 9,
    'nine': 9,
    'sampu': 10,
    'sampung': 10,
    'ten': 10,
    'labinlima': 15,
    'fifteen': 15,
    'dalawampu': 20,
    'dalawampung': 20,
    'twenty': 20,
    'tatlumpu': 30,
    'tatlumpung': 30,
    'thirty': 30,
    'apatnapu': 40,
    'forty': 40,
    'limampu': 50,
    'fifty': 50,
    'animnapu': 60,
    'sixty': 60,
  };

  static const Set<String> _personWords = {
    'pasyente',
    'biktima',
    'tao',
    'patient',
    'patients',
    'victim',
    'victims',
    'casualty',
    'casualties',
    'sugatan',
    'survivor',
    'survivors',
    'injured',
    'bata',
    'anak',
    'child',
    'children',
    'kids',
    'kid',
    'sanggol',
    'baby',
    'babies',
    'infant',
    'matanda',
    'lolo',
    'lola',
    'adult',
    'adults',
    'buntis',
    'lalaki',
    'babae',
  };

  static const Set<String> _minuteWords = {
    'minuto',
    'minuta',
    'minute',
    'minutes',
    'min',
    'mins',
  };
  static const Set<String> _hourWords = {'oras', 'hour', 'hours', 'hr', 'hrs'};

  /// Tagalog clitics, linkers and politeness particles may sit inside a phrase
  /// without changing its claim: "nahihirapan siyang huminga" is still
  /// "nahihirapan huminga". Negators and content words are deliberately absent,
  /// so a skipped particle can never hide a denial or an unrelated word.
  static const Set<String> _clitics = {
    'po',
    'ho',
    'opo',
    'oho',
    'na',
    'ng',
    'nang',
    'pa',
    'ba',
    'nga',
    'naman',
    'lang',
    'lamang',
    'din',
    'rin',
    'daw',
    'raw',
    'talaga',
    'muna',
    'pala',
    'yata',
    'ulit',
    'sana',
    'ay',
    'yung',
    'eh',
    'ako',
    'akong',
    'ka',
    'kang',
    'ko',
    'kong',
    'mo',
    'mong',
    'siya',
    'siyang',
    'niya',
    'niyang',
    'kami',
    'kaming',
    'tayo',
    'tayong',
    'kayo',
    'kayong',
    'sila',
    'silang',
    'namin',
    'nating',
    'natin',
    'nila',
    'nilang',
    'kaniya',
    'kanya',
    'kanyang',
    'akin',
    'atin',
    'ating',
  };
  static const int _maxCliticGap = 4;

  TriageResult parse(String transcript) {
    final tokens = _tokenize(transcript);

    var matched = [
      for (final d in _injuries)
        if (d.variants.any((v) => _containsPhrase(tokens, v))) d,
    ];
    final hidden = {for (final d in matched) ...d.supersedes};
    matched = matched.where((d) => !hidden.contains(d.name)).toList();

    return TriageResult(
      location: _findLocation(tokens) ?? unknownLocation,
      injuries: [for (final d in matched) d.name],
      triage: _triageOf(matched),
      patientCount: _patientCount(tokens),
      ageGroup: _ageGroup(tokens),
      etaMinutes: _etaMinutes(tokens),
      rawText: transcript,
    );
  }

  /// Worst finding wins (over-triage is the safe direction).
  static String _triageOf(List<_Injury> found) {
    if (found.isEmpty) return unassessed;
    final tiers = found.map((d) => d.tier).toSet();
    if (tiers.contains(_Tier.immediate)) return immediate;
    if (tiers.contains(_Tier.delayed)) return delayed;
    if (tiers.contains(_Tier.minor)) return minor;
    return deceased;
  }

  static String? _findLocation(List<String> tokens) {
    for (final entry in locations.entries) {
      if (entry.value.any((v) => _containsPhrase(tokens, v))) {
        return 'Barangay ${entry.key}';
      }
    }
    return null;
  }

  static String _ageGroup(List<String> tokens) {
    for (final entry in _ageGroups.entries) {
      if (tokens.any(entry.value.contains)) return entry.key;
    }
    return unspecified;
  }

  static int? _number(String t) => int.tryParse(t) ?? _numberWords[t];

  /// "dalawang bata", "3 patients", "isang buntis". Defaults to 1.
  static int _patientCount(List<String> tokens) {
    for (var i = 0; i + 1 < tokens.length; i++) {
      final n = _number(tokens[i]);
      if (n == null || n < 1 || n > 99) continue;
      // Allow clitics/linkers: "dalawa na bata", "tatlong po siyang tao".
      var j = i + 1;
      var skipped = 0;
      while (j < tokens.length &&
          skipped < _maxCliticGap &&
          _clitics.contains(tokens[j])) {
        j++;
        skipped++;
      }
      if (j < tokens.length && _personWords.contains(tokens[j])) return n;
    }
    return 1;
  }

  /// "sampung minuto", "15 minutes", "isang oras", "kalahating oras".
  static int? _etaMinutes(List<String> tokens) {
    for (var i = 0; i + 1 < tokens.length; i++) {
      final unit = tokens[i + 1];
      if ((tokens[i] == 'kalahating' && unit == 'oras') ||
          (tokens[i] == 'half' && unit == 'hour')) {
        return 30;
      }
      final n = _number(tokens[i]);
      if (n == null || n < 1) continue;
      final minutes = _minuteWords.contains(unit)
          ? n
          : _hourWords.contains(unit)
          ? n * 60
          : null;
      if (minutes != null && minutes <= 720) return minutes;
    }
    return null;
  }

  static List<String> _tokenize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-zñ0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();

  /// Sliding-window phrase match where each word may differ slightly and
  /// Tagalog clitic particles between words are skipped: "nahihirapan siyang
  /// huminga" still matches "nahihirapan huminga".
  static bool _containsPhrase(List<String> tokens, String phrase) {
    final words = phrase.split(' ');
    for (var i = 0; i < tokens.length; i++) {
      if (_matchWords(tokens, i, words, 0)) return true;
    }
    return false;
  }

  /// Matches `words[j]` onward at `tokens[i]`, allowing up to [_maxCliticGap]
  /// clitic particles between consecutive phrase words. Only starts skipping
  /// after the first word matched, so a phrase cannot start inside a clitic run.
  static bool _matchWords(
    List<String> tokens,
    int i,
    List<String> words,
    int j,
  ) {
    if (j == words.length) return true;
    var k = i;
    var skipped = 0;
    while (k < tokens.length) {
      if (_close(tokens[k], words[j]) &&
          _matchWords(tokens, k + 1, words, j + 1)) {
        return true;
      }
      if (j > 0 && skipped < _maxCliticGap && _clitics.contains(tokens[k])) {
        skipped++;
        k++;
        continue;
      }
      return false;
    }
    return false;
  }

  /// Edit tolerance only for long keywords. Short Tagalog words differ by one
  /// letter from unrelated words ("nabali" vs "nabalik" = fractured vs
  /// returned), so anything under 7 letters must match exactly.
  static bool _close(String token, String keyword) {
    if (token == keyword) return true;
    final allowed = keyword.length >= 10
        ? 2
        : keyword.length >= 7
        ? 1
        : 0;
    if (allowed == 0 || (token.length - keyword.length).abs() > allowed) {
      return false;
    }
    return _levenshtein(token, keyword) <= allowed;
  }

  static int _levenshtein(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = [
          prev[j] + 1,
          cur[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      prev = cur;
    }
    return prev[b.length];
  }
}
