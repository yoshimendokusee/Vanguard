import Foundation

/// Swift port of the hub's observation confirmation (`CONFIRM`, `findPhrase`, `oppositeOf` and
/// `toValidatedExtraction` in `hub/ai.js`). A model claim counts only when a phrase that really means
/// that value occurs in the transcript as a whole word. The model's own quote is never trusted, so a
/// transcript cannot talk the model into an observation, and a denial ("no severe bleeding") or a
/// conflicting statement leaves the observation unknown. `docs/fixtures/observation-parity-v1.json`
/// is generated from the hub validator and `ObservationParityTests` must match it exactly.
public enum ObservationConfirmation {
    static let phrases: [String: [String: [String]]] = [
        "breathing": [
            "absent": ["not breathing", "hindi humihinga", "no breathing", "stopped breathing", "walang paghinga"],
            "abnormal": ["difficulty breathing", "nahihirapan huminga", "hirap huminga", "drowning", "nalunod", "shortness of breath",
                         "trouble breathing", "gasping", "difficulty of breathing"],
            "normal": ["breathing normally", "normal breathing", "breathing fine", "breathing ok", "humihinga nang normal", "normal huminga"],
        ],
        "consciousness": [
            "unresponsive": ["unconscious", "walang malay", "unresponsive", "not responding", "no response", "passed out",
                             "nawalan ng malay", "unconsciousness"],
            "alert": ["awake", "gising", "alert", "conscious", "responsive", "mulat"],
        ],
        "severeBleeding": [
            "present": ["severe bleeding", "malakas na pagdurugo", "heavy bleeding", "lots of blood", "maraming dugo",
                        "severe blood loss", "bleeding heavily", "bleeding a lot", "profuse bleeding"],
            "absent": ["no severe bleeding", "no bleeding", "walang dugo", "walang pagdurugo", "no blood", "bleeding stopped"],
        ],
        "walking": [
            "unable": ["cannot walk", "can't walk", "hindi makalakad", "cannot stand", "unable to walk", "could not walk", "cant walk"],
            "able": ["can walk", "nakakalakad", "able to walk", "walking"],
        ],
    ]
    /// Same iteration order as the hub's `ALLOWED` keys.
    static let order = ["breathing", "consciousness", "severeBleeding", "walking"]

    struct Hit { let quote: String; let start: Int; let end: Int }

    /// First phrase (in list order) that occurs as a whole word, case-insensitively.
    static func find(_ transcript: String, _ list: [String]) -> Hit? {
        let text = transcript as NSString
        for phrase in list {
            guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: transcript, range: NSRange(location: 0, length: text.length)) else { continue }
            return Hit(quote: String(text.substring(with: match.range).prefix(120)), start: match.range.location, end: match.range.location + match.range.length)
        }
        return nil
    }

    static func opposite(_ key: String, _ value: String) -> [String] {
        switch key {
        case "breathing": return value == "normal" ? ["absent", "abnormal"] : value == "unknown" ? [] : ["normal"]
        case "consciousness": return value == "alert" ? ["unresponsive"] : value == "unresponsive" ? ["alert"] : []
        case "severeBleeding": return value == "present" ? ["absent"] : value == "absent" ? ["present"] : []
        case "walking": return value == "able" ? ["unable"] : value == "unable" ? ["able"] : []
        default: return []
        }
    }

    public struct Result: Equatable, Sendable {
        public let observations: [String: String]
        /// The transcript text that confirmed each non-unknown observation.
        public let evidence: [String: String]
        public let warnings: [String]
    }

    /// `claims` are what the model said. Anything the transcript does not support becomes unknown.
    public static func confirm(claims: [String: String], transcript: String) -> Result {
        var observations: [String: String] = [:], evidence: [String: String] = [:], warnings: [String] = []
        for key in order {
            var value = claims[key].flatMap { TriageRules.allowed[key]?.contains($0) == true ? $0 : nil } ?? "unknown"
            if value != "unknown" {
                if let hit = find(transcript, phrases[key]?[value] ?? []) {
                    let conflict = opposite(key, value).compactMap { find(transcript, phrases[key]?[$0] ?? []) }
                        // A denial ("no severe bleeding") contains the positive phrase: an opposite match
                        // strictly inside the confirming span is the denial itself, not a conflict.
                        .contains { !($0.start >= hit.start && $0.end <= hit.end) }
                    if conflict {
                        value = "unknown"; warnings.append("Contradictory statements about \(key); treated as unknown")
                    } else { evidence[key] = hit.quote }
                } else {
                    value = "unknown"; warnings.append("Unconfirmed claim for \(key) was treated as unknown (no transcript evidence)")
                }
            }
            observations[key] = value
        }
        return Result(observations: observations, evidence: evidence, warnings: warnings)
    }
}
