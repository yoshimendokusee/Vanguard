import Foundation

/// Provisional triage categories, spelled exactly as the hub stores them.
public enum TriageCategory: String, Codable, Sendable, CaseIterable {
    case immediate = "Immediate", delayed = "Delayed", minor = "Minor", unassessed = "Unassessed"
}

public struct ProvisionalTriage: Codable, Equatable, Sendable {
    public let triage: TriageCategory
    public let reason: String
    public let version: String
}

/// Swift port of `assessRisk` in `hub/risk.js`. It must stay identical to the hub:
/// `docs/fixtures/triage-parity-v1.json` holds every observation combination, the hub
/// test locks the fixture to `risk.js`, and `TriageParityTests` locks this file to it.
/// Qwen only supplies the observations. It never decides urgency, and unknown never
/// means normal. The result is provisional and needs qualified verification.
public enum TriageRules {
    public static let ruleVersion = "provisional-v1"
    public static let allowed: [String: [String]] = [
        "breathing": ["normal", "abnormal", "absent", "unknown"],
        "consciousness": ["alert", "unresponsive", "unknown"],
        "severeBleeding": ["present", "absent", "unknown"],
        "walking": ["able", "unable", "unknown"],
    ]

    public static func isValid(_ observations: [String: String]) -> Bool {
        observations.count == allowed.count
            && allowed.allSatisfy { key, values in observations[key].map(values.contains) ?? false }
    }

    /// Returns nil for observations outside the schema rather than guessing.
    public static func assess(_ observations: [String: String]) -> ProvisionalTriage? {
        guard isValid(observations) else { return nil }
        var reasons: [String] = []
        let breathing = observations["breathing"]!
        if breathing == "abnormal" || breathing == "absent" { reasons.append("Breathing: \(breathing)") }
        if observations["consciousness"] == "unresponsive" { reasons.append("Unresponsive") }
        if observations["severeBleeding"] == "present" { reasons.append("Severe bleeding reported") }
        var triage = TriageCategory.unassessed
        if !reasons.isEmpty {
            triage = .immediate
        } else if observations["walking"] == "unable" {
            triage = .delayed
            reasons.append("Unable to walk; other critical findings not established")
        } else if observations["walking"] == "able", breathing == "normal",
            observations["consciousness"] == "alert", observations["severeBleeding"] == "absent" {
            triage = .minor
            reasons.append("Walking, alert, normal breathing, no severe bleeding reported")
        } else {
            reasons.append("Insufficient explicit observations; qualified assessment required")
        }
        return ProvisionalTriage(triage: triage, reason: reasons.joined(separator: "; "), version: ruleVersion)
    }
}
