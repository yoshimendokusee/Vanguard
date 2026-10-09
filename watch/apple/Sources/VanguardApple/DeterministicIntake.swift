import Foundation

/// Deterministic report-field extraction, a Swift port of `hub/intake.js`. Qwen3-0.6B cannot follow a structured
/// findings schema reliably (see LiveExtractionTests), so location, patient count, age group, ETA and symptom
/// terms come from these quote-grounded rules instead. Each value is paired with the exact transcript text it
/// came from and anything not stated stays unknown. Nothing here assigns urgency.
/// `docs/fixtures/intake-parity-v1.json` is generated from the hub and `IntakeParityTests` must match it.
public enum DeterministicIntake {
    struct Located: Equatable { let value: String; let basis: String; let evidence: String }
    struct Counted: Equatable { let value: Int; let evidence: String }
    struct Grouped: Equatable { let value: String; let evidence: String; let mixed: Bool }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "isa": 1, "isang": 1, "dalawa": 2, "dalawang": 2, "tatlo": 3, "tatlong": 3, "apat": 4, "lima": 5, "limang": 5,
        "anim": 6, "pito": 7, "pitong": 7, "walo": 8, "walong": 8, "siyam": 9, "sampu": 10, "sampung": 10,
    ]
    private static let num = "(\\d{1,3}|\(numberWords.keys.joined(separator: "|")))"
    private static func toNumber(_ token: String) -> Int? { Int(token) ?? numberWords[token.lowercased()] }

    private static let patientNouns = "patients?|pasyente|victims?|biktima|casualt(?:y|ies)|persons?|people|tao|katao|injured|sugatan|bata|children|kids?|adults?|matanda|lalaki|babae|survivors?|riders?|passengers?"
    private static let etaCues = "\\b(eta|arriv\\w*|away|out|papunta|patungo|darating|dadating|dating|on the way|en route|to the hospital|sa ospital|bago makarating|makarating)\\b"

    private static let notPlace: Set<String> = ["a", "an", "the", "my", "his", "her", "their", "our", "ang", "ng", "mga", "si", "ni", "kay", "akin", "kanya", "critical", "serious",
        "severe", "pain", "shock", "labor", "labour", "distress", "danger", "trouble", "condition", "ospital", "hospital", "er", "ed", "emergency", "ambulansya",
        "ambulance", "sakit", "hirap", "dugo", "blood", "tubig", "water", "moment", "minutes", "minuto", "oras", "hours", "araw", "days", "order", "case", "need",
        "progress", "process", "general", "total", "fact", "addition", "front", "back", "about", "around", "ibang", "iba", "pagitan", "gitna", "labas", "loob", "bubong", "puno", "hagdan", "kama", "sahig", "traffic", "roof", "tree", "stairs", "bed", "floor", "ladder"]
    private static let placeStop: Set<String> = ["and", "at", "na", "with", "po", "ang", "ay", "ng", "mga", "papunta", "to", "who", "which", "that", "are", "is", "was", "were",
        "after", "because", "but", "pero", "kasi", "dahil", "habang", "ngayon", "now", "today", "kanina", "around", "about", "for", "please", "help", "tulong",
        "nahulog", "nabangga", "sumasakit", "masakit", "may", "walang", "hindi", "dalawa", "dalawang", "ten", "eta", "male", "female", "patient", "pasyente"]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static func ns(_ text: String) -> NSString { text as NSString }
    private static func all(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [NSTextCheckingResult] {
        regex(pattern, options).matches(in: text, range: NSRange(location: 0, length: ns(text).length))
    }

    // MARK: Location

    private static func wordsAfter(_ text: String, from: Int) -> [(text: String, end: Int)] {
        var words: [(String, Int)] = []
        let t = ns(text)
        let re = regex("[\\p{L}\\p{N}][\\p{L}\\p{N}'’.-]*", [])
        var cursor = from
        while words.count < 3, let m = re.firstMatch(in: text, range: NSRange(location: cursor, length: t.length - cursor)) {
            cursor = m.range.location + m.range.length
            let word = t.substring(with: m.range)
            if let last = words.last {
                let gap = t.substring(with: NSRange(location: last.1, length: m.range.location - last.1))
                if gap.range(of: "[,;:()!?]", options: .regularExpression) != nil { break }
            }
            if placeStop.contains(word.lowercased()) { break }
            words.append((word.replacingOccurrences(of: "[.'’-]+$", with: "", options: .regularExpression), cursor))
        }
        return words
    }

    static func findLocation(_ transcript: String, pack: TermPack?) -> Located? {
        let patterns = ["\\b(?:barangay|brgy\\.?|bgy\\.?)\\s+(?=\\p{L})", "\\b(?:purok|sitio|zone)\\s+(?=[\\p{L}\\p{N}])",
                        "\\b(?:malapit sa|dito sa|mula sa|galing sa|taga-?|near|from|in|at|sa)\\s+(?=\\p{L})"]
        let t = ns(transcript)
        for (position, pattern) in patterns.enumerated() {
            for m in all(pattern, in: transcript) {
                let marker = t.substring(with: m.range)
                let words = wordsAfter(transcript, from: m.range.location + m.range.length)
                guard let firstWord = words.first else { continue }
                if position == 2 && notPlace.contains(firstWord.text.lowercased()) { continue }
                // Tagalog "at" means "and": a place marker only before a capitalized name.
                if position == 2 && marker.range(of: "^at\\s", options: [.regularExpression, .caseInsensitive]) != nil
                    && firstWord.text.unicodeScalars.first.map({ !CharacterSet.uppercaseLetters.contains($0) }) ?? true { continue }
                let value = words.map(\.text).joined(separator: " ")
                if position == 2, let pack, pack.retrieve(value).contains(where: { $0.matched == TermPack.normalize(value) }) { continue }
                let trimmed = marker.trimmingCharacters(in: .whitespaces)
                let isBarangay = marker.range(of: "^(?:brgy|bgy|barangay)", options: [.regularExpression, .caseInsensitive]) != nil
                let label = position < 2 ? "\(isBarangay ? "Barangay" : trimmed.prefix(1).uppercased() + trimmed.dropFirst()) \(value)" : value
                // Title-case only an all-lowercase place so the form reads naturally; the evidence stays verbatim.
                let shown = label == label.lowercased()
                    ? ns(label).replacingOccurrences(of: "\\b\\p{L}", with: "$0", options: .regularExpression, range: NSRange(location: 0, length: ns(label).length)) : label
                let titled = label == label.lowercased() ? titleCase(label) : shown
                return Located(value: titled, basis: position < 2 ? "explicit" : "inferred",
                               evidence: t.substring(with: NSRange(location: m.range.location, length: words.last!.end - m.range.location)))
            }
        }
        return nil
    }

    /// Uppercase the first letter after each word boundary (JS `\b\p{L}`), without touching the rest.
    private static func titleCase(_ text: String) -> String {
        var out = "", startOfWord = true
        for ch in text {
            let isWordChar = ch.isLetter || ch.isNumber || ch == "_"
            out += (startOfWord && ch.isLetter) ? String(ch).uppercased() : String(ch)
            startOfWord = !isWordChar
        }
        return out
    }

    // MARK: Count, age group, ETA

    static func findPatientCount(_ transcript: String) -> Counted? {
        guard let m = all("\\b\(num)\\s+(?:na\\s+)?(?:\(patientNouns))\\b", in: transcript).first else { return nil }
        let t = ns(transcript)
        guard let value = toNumber(t.substring(with: m.range(at: 1))), (1...99).contains(value) else { return nil }
        return Counted(value: value, evidence: t.substring(with: m.range))
    }

    static func bandForYears(_ years: Int) -> String? {
        if years < 1 { return "Infant" }
        if years <= 12 { return "Child" }
        if years >= 60 { return "Elderly" }
        if years >= 18 { return "Adult" }
        return nil   // 13-17 is ambiguous: left for the reviewer
    }

    static func findAgeGroup(_ transcript: String) -> Grouped? {
        var found: [(group: String, evidence: String)] = []
        func add(_ group: String?, _ evidence: String) { if let group, !found.contains(where: { $0.group == group }) { found.append((group, evidence)) } }
        let t = ns(transcript)
        for m in all("\\b(\\d{1,3})[\\s-]*(?:years?|yrs?|yr|taong|taon|anyos|y/?o)(?:[\\s-]*old|\\s+gulang)?\\b", in: transcript) {
            add(bandForYears(Int(t.substring(with: m.range(at: 1)))!), t.substring(with: m.range))
        }
        for m in all("\\b(\\d{1,2})[\\s-]*(?:months?|buwan)(?:[\\s-]*old)?\\b", in: transcript) {
            add(Int(t.substring(with: m.range(at: 1)))! < 12 ? "Infant" : "Child", t.substring(with: m.range))
        }
        let words: [(String, String)] = [
            ("Infant", "\\b(infants?|babies|baby|newborns?|sanggol|bagong silang)\\b"),
            ("Child", "\\b(child|children|kids?|toddlers?|bata|mga bata|paslit)\\b"),
            ("Elderly", "\\b(elderly|seniors?|senior citizens?|lolo|lola|nakatatanda|matanda na|old (?:man|woman))\\b"),
            ("Adult", "\\b(adults?|nasa hustong gulang)\\b"),
        ]
        for (group, pattern) in words { if let m = all(pattern, in: transcript).first { add(group, t.substring(with: m.range)) } }
        if found.count != 1 { return found.isEmpty ? nil : Grouped(value: "Unspecified", evidence: found.map(\.evidence).joined(separator: " / "), mixed: true) }
        return Grouped(value: found[0].group, evidence: found[0].evidence, mixed: false)
    }

    static func findEta(_ transcript: String) -> Counted? {
        let t = ns(transcript)
        for m in all("\\b\(num)\\s*(?:(minutes?|mins?|minuto)|(hours?|hrs?|oras))\\b", in: transcript) {
            // Only a minutes figure next to an arrival cue is an ETA: "unconscious for 10 minutes" is not.
            let from = max(0, m.range.location - 60), to = min(t.length, m.range.location + m.range.length + 60)
            let around = t.substring(with: NSRange(location: from, length: to - from))
            guard all(etaCues, in: around).first != nil, let n = toNumber(t.substring(with: m.range(at: 1))) else { continue }
            // "30 minutes ago" / "mga 30 minutes na" says how long it has been, not when they arrive ("na lang" stays an ETA).
            let after = NSRange(location: m.range.location + m.range.length, length: min(14, t.length - (m.range.location + m.range.length)))
            if all("^\\s*(?:ago\\b|already\\b|na\\b(?!\\s+lang))", in: t.substring(with: after)).first != nil { continue }
            let minutes = n * (m.range(at: 3).location != NSNotFound ? 60 : 1)
            if (1...720).contains(minutes) { return Counted(value: minutes, evidence: t.substring(with: m.range)) }
        }
        return nil
    }

    // MARK: Whole report

    /// What was stated in the transcript, with the quote behind each value.
    public struct Result: Equatable, Sendable {
        public let details: ReportDetails
        public let evidence: [String: String]
        public let locationBasis: String?
        public let notes: [String]
        public let terms: [TermMatch]
    }

    private static let findingCategories: Set<String> = ["injury", "condition", "mechanism", "symptom"]

    public static func extract(from transcript: String, pack: TermPack?) -> Result {
        let location = findLocation(transcript, pack: pack), count = findPatientCount(transcript)
        let age = findAgeGroup(transcript), eta = findEta(transcript)
        var evidence: [String: String] = [:]
        if let location { evidence["location"] = location.evidence }
        if let count { evidence["patientCount"] = count.evidence }
        if let age { evidence["ageGroup"] = age.evidence }
        if let eta { evidence["etaMinutes"] = eta.evidence }
        return Result(details: ReportDetails(location: location?.value, patientCount: count?.value, ageGroup: age?.value ?? "Unspecified", etaMinutes: eta?.value),
                      evidence: evidence, locationBasis: location?.basis,
                      notes: age?.mixed == true ? ["Different age groups were mentioned; age group left unspecified"] : [],
                      terms: pack?.retrieve(transcript, limit: 12) ?? [])
    }

    /// Symptom/injury terms found in the transcript as findings in the hub's `findings` shape. Quotes are the
    /// transcript's own words (matched phrase in normalized form is mapped back to the original text).
    public static func findings(for transcript: String, terms: [TermMatch]) -> [NativeProcessing.Finding] {
        var out: [NativeProcessing.Finding] = []
        for term in terms where !term.negated && findingCategories.contains(term.category) {
            guard let quote = originalText(of: term.matched, in: transcript) else { continue }
            out.append(NativeProcessing.Finding(id: "t\(out.count + 1)", kind: "symptom", name: term.english.lowercased(), value: nil, unit: nil,
                                                source: "reported", excerpt: quote, contradictory: false))
        }
        return out
    }

    /// Finds the original-case, original-accent text a normalized phrase came from. Returns nil rather than guessing.
    static func originalText(of normalizedPhrase: String, in transcript: String) -> String? {
        let words = normalizedPhrase.split(separator: " ").map { $0 == "ang" ? "(?:ang|yung|yong)" : NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let separator = "[^\\p{L}\\p{N}]+(?:(?:\(TermPack.fillers.joined(separator: "|")))[^\\p{L}\\p{N}]+)?"
        let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: separator) + "(?![\\p{L}\\p{N}])"
        guard let m = all(pattern, in: transcript).first else { return nil }
        let quote = ns(transcript).substring(with: m.range)
        return transcript.contains(quote) ? quote : nil
    }
}
