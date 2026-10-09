import Foundation

public enum ObservationPresentation {
    public static let labels = ["breathing": "Breathing", "consciousness": "Consciousness", "severeBleeding": "Severe Bleeding", "walking": "Walking", "circulation": "Circulation"]
    public static func status(_ key: String, _ value: String?) -> String {
        let statuses = [
            "breathing": ["normal": "Reported normal", "abnormal": "Difficulty breathing", "absent": "Not breathing"],
            "consciousness": ["alert": "Responsive", "confused": "Confused / altered", "unresponsive": "Unresponsive"],
            "severeBleeding": ["present": "Severe bleeding reported", "absent": "No severe bleeding reported", "uncertain": "Severity uncertain"],
            "walking": ["able": "Independent", "unable": "Unable", "assisted": "With assistance"],
            "circulation": ["present": "Radial pulse palpable", "absent": "Radial pulse not palpable", "uncertain": "Uncertain"]]
        return statuses[key]?[value ?? "unknown"] ?? "Unknown / unassessed"
    }
    public static func summary(_ observations: [String: String]) -> String {
        ObservationConfirmation.order.map { "\(labels[$0] ?? $0): \(status($0, observations[$0]))" }.joined(separator: "\n")
    }
}
