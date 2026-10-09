import Foundation

/// Everything the transcript states, each value with the quote behind it. Built only from deterministic,
/// quote-grounded rules (`DeterministicIntake` plus a few Swift-only display helpers below). Unstated values
/// stay unknown. Nothing here assigns urgency: triage is `TriageRules` on the four validated observations.
public struct ExtractedReport: Equatable, Sendable {
    public var details: ReportDetails
    /// The exact transcript text behind each filled field, keyed by field name.
    public var evidence: [String: String]
    public var locationBasis: String?
    public var sex: String?
    public var ageYears: Int?
    public var ageIsApproximate: Bool
    public var onsetMinutes: Int?
    /// Reported symptoms/injuries (never vital signs) in the hub's `findings` shape.
    public var findings: [NativeProcessing.Finding]
    public var notes: [String]
}

public enum ReportExtraction {
    private static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "isa": 1, "dalawa": 2, "tatlo": 3, "apat": 4, "lima": 5, "anim": 6, "pito": 7, "walo": 8, "siyam": 9, "sampu": 10,
        "isang": 1, "dalawang": 2, "tatlong": 3, "limang": 5, "pitong": 7, "walong": 8, "sampung": 10]

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]).firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// Age in years (and whether the speaker hedged: around, about, mga ...). Display only.
    static func age(in transcript: String) -> (years: Int, approximate: Bool, quote: String)? {
        let t = transcript as NSString
        guard let m = firstMatch("(?:(around|about|approximately|approx|roughly|mga|halos|tinatayang)\\s+)?\\b(\\d{1,3})[\\s-]*(?:years?|yrs?|yr|taong|taon|anyos)(?:[\\s-]*old|\\s+gulang)?\\b", in: transcript),
              let years = Int(t.substring(with: m.range(at: 2))), (0...120).contains(years) else { return nil }
        return (years, m.range(at: 1).location != NSNotFound, t.substring(with: m.range))
    }

    /// Minutes since the problem began ("30 minutes ago", "mga 30 minutes na"). Not an ETA.
    static func onset(in transcript: String) -> (minutes: Int, quote: String)? {
        let t = transcript as NSString
        let number = "(\\d{1,4}|\(numberWords.keys.joined(separator: "|")))"
        guard let m = firstMatch("\\b\(number)\\s*(minutes?|mins?|minuto|hours?|hrs?|oras)\\s+(?:ago|na|already)\\b", in: transcript),
              let value = Int(t.substring(with: m.range(at: 1))) ?? numberWords[t.substring(with: m.range(at: 1)).lowercased()] else { return nil }
        let isHours = ["hour", "hours", "hr", "hrs", "oras"].contains(t.substring(with: m.range(at: 2)).lowercased())
        let minutes = value * (isHours ? 60 : 1)
        return (1...100_000).contains(minutes) ? (minutes, t.substring(with: m.range)) : nil
    }

    /// Only a single, unambiguous sex word counts; "male and female" or none leaves it unknown.
    static func sex(in transcript: String) -> (value: String, quote: String)? {
        let groups: [(String, String)] = [("male", "\\b(male|man|boy|lalaki)\\b"), ("female", "\\b(female|woman|girl|babae)\\b")]
        let hits = groups.compactMap { value, pattern -> (String, String)? in
            firstMatch(pattern, in: transcript).map { (value, (transcript as NSString).substring(with: $0.range)) }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    public static func extract(transcript: String, pack: TermPack?) -> ExtractedReport {
        let intake = DeterministicIntake.extract(from: transcript, pack: pack)
        var findings = DeterministicIntake.findings(for: transcript, terms: intake.terms)
        let age = age(in: transcript), onset = onset(in: transcript), sex = sex(in: transcript)
        func add(_ kind: String, _ name: String, _ value: String?, _ unit: String?, _ quote: String) {
            findings.append(NativeProcessing.Finding(id: "p\(findings.count + 1)", kind: kind, name: name, value: value, unit: unit,
                                                     source: "reported", excerpt: quote, contradictory: false))
        }
        if let age { add("patient", "age", String(age.years), "years", age.quote) }
        if let sex { add("patient", "sex", sex.value, nil, sex.quote) }
        if let count = intake.details.patientCount, let quote = intake.evidence["patientCount"] { add("patient", "patient_count", String(count), nil, quote) }
        if let place = intake.details.location, let quote = intake.evidence["location"] { add("incident", "pickup_location", place, nil, quote) }
        if let eta = intake.details.etaMinutes, let quote = intake.evidence["etaMinutes"] { add("incident", "eta_minutes", String(eta), "minutes", quote) }
        if let onset { add("incident", "onset_minutes", String(onset.minutes), "minutes", onset.quote) }
        return ExtractedReport(details: intake.details, evidence: intake.evidence, locationBasis: intake.locationBasis, sex: sex?.value,
                               ageYears: age?.years, ageIsApproximate: age?.approximate ?? false, onsetMinutes: onset?.minutes,
                               findings: Array(findings.prefix(100)), notes: intake.notes)
    }
}
