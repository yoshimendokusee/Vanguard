import Foundation

/// Same grounding as hub/observation-confirmation.js, locked by shared parity fixtures.
// shortcut: bounded language grounding, expand only with reviewed phrases and shared regression cases.
public enum ObservationConfirmation {
    static let order = ["breathing", "consciousness", "severeBleeding", "walking", "circulation"]
    private struct Language: Decodable {
        let phrases: [String: [String: [String]]]
        let mentions: [String: String]
        let uncertainty, unassessed, otherSubject, multiplePatients, instruction, correction, historical, gap, negation: String
    }
    private static let language: Language? = {
        guard let file = Bundle.module.url(forResource: "observation-phrases", withExtension: "json") else { return nil }
        return try? JSONDecoder().decode(Language.self, from: Data(contentsOf: file))
    }()
    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?
            .matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? []
    }
    private static func test(_ pattern: String, _ text: String) -> Bool { !matches(pattern, text).isEmpty }
    private struct Hit { let value: String; let quote: String?; var start = 0; var end = 0 }
    public struct Result: Equatable, Sendable {
        public let observations: [String: String]
        public let evidence: [String: String]
        public let warnings: [String]
    }

    public static func confirm(claims: [String: String], transcript: String) -> Result {
        var observations: [String: String] = [:], evidence: [String: String] = [:], warnings: [String] = []
        guard let language else {
            return Result(observations: Dictionary(uniqueKeysWithValues: order.map { ($0, "unknown") }), evidence: [:], warnings: ["Observation language pack unavailable; all observations unknown"])
        }
        let multiple = test(language.multiplePatients, transcript)
        let text = transcript as NSString
        let splits = matches("(?<=\\?)|[.!;,\\n]+|(?=\\b(?:correction|actually|now|ngayon|pala)\\b)", transcript)
        var clauses: [String] = [], offset = 0
        for split in splits {
            clauses.append(text.substring(with: NSRange(location: offset, length: split.range.location - offset)))
            offset = split.range.location + split.range.length
        }
        clauses.append(text.substring(from: offset))
        for key in order {
            var hits: [Hit] = []
            for clause in clauses {
                if multiple || test(language.otherSubject, clause) || test(language.instruction, clause) { continue }
                let phrases = language.phrases[key] ?? [:]
                if !test(language.mentions[key] ?? "(?!)", clause) && !phrases.values.flatMap({ $0 }).contains(where: { clause.lowercased().contains($0) }) { continue }
                if test(language.correction, clause) { hits = [] }
                if test(language.unassessed, clause) || (test(language.historical, clause) && !test(language.correction, clause)) {
                    hits.append(Hit(value: "unknown", quote: nil)); continue
                }
                if test(language.uncertainty, clause) {
                    hits.append(Hit(value: ["circulation", "severeBleeding"].contains(key) ? "uncertain" : "unknown",
                                    quote: String(clause.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))); continue
                }
                var found: [Hit] = []
                let source = clause as NSString
                // Stable state order matches the bundled JSON/hub even when phrases overlap.
                for value in ["absent", "abnormal", "normal", "unresponsive", "alert", "confused", "present", "uncertain", "unable", "able", "assisted"] {
                    for phrase in phrases[value] ?? [] {
                        let pattern = phrase.components(separatedBy: " ").map(NSRegularExpression.escapedPattern).joined(separator: language.gap)
                        for match in matches("\\b\(pattern)\\b(?![-\\w])", clause) {
                            if !test(language.negation, source.substring(to: match.range.location)) {
                                found.append(Hit(value: value, quote: source.substring(with: match.range), start: match.range.location, end: match.range.location + match.range.length))
                            }
                        }
                    }
                }
                found = found.filter { hit in !found.contains { other in other.value != hit.value && other.start <= hit.start && other.end >= hit.end } }
                hits.append(contentsOf: found)
            }
            let values = Set(hits.map(\.value))
            let value = values.count == 1 ? hits[0].value : "unknown"
            observations[key] = value
            if value != "unknown", let quote = hits.first?.quote { evidence[key] = String(quote.prefix(120)) }
            if values.count > 1 { warnings.append("Contradictory statements about \(key); treated as unknown") }
            else if let claim = claims[key], claim != value { warnings.append("Unconfirmed claim for \(key); used transcript-grounded \(value)") }
        }
        return Result(observations: observations, evidence: evidence, warnings: warnings)
    }
}
