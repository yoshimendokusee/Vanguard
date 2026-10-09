import Foundation

public struct NativeProcessing: Codable, Sendable {
    public struct Evidence: Codable, Sendable {
        public let source: String
        public let excerpt: String
        public let contradictory: Bool
    }
    public struct Extraction: Codable, Sendable {
        public let model: String
        public let revision: String
        public let runtime: String
        public let artifactSha256: String
        public let execution: String
    }
    public struct Provenance: Codable, Sendable {
        public let device: String
        public let sttEngine: String
        public let sttRuntime: String
        public let extraction: Extraction
    }
    /// A symptom, patient or incident detail with the exact transcript text it came from.
    /// Same shape as the hub's `findings` (hub/processing.js); names are English normalizations.
    public struct Finding: Codable, Sendable, Equatable {
        public let id: String
        public let kind: String
        public let name: String
        public let value: String?
        public let unit: String?
        public let source: String
        public let excerpt: String?
        public let contradictory: Bool

        enum CodingKeys: String, CodingKey { case id, kind, name, value, unit, source, excerpt, contradictory }
        /// The hub's validator requires `value` to be present: an explicit null, never an omitted key.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(name, forKey: .name)
            try c.encode(value, forKey: .value)               // null when unknown
            try c.encodeIfPresent(unit, forKey: .unit)
            try c.encode(source, forKey: .source); try c.encodeIfPresent(excerpt, forKey: .excerpt)
            try c.encode(contradictory, forKey: .contradictory)
        }
    }
    public static let findingKinds = ["symptom", "observation", "vital", "patient", "incident"]
    public let version: Int
    public let originalTranscript: String
    public let observations: [String: String]
    public let evidence: [String: Evidence]
    public let uncertainties: [String]
    public let provenance: Provenance
    /// Optional so version-1 rows saved before structured findings still decode and validate.
    public var findings: [Finding]? = nil

    public var isValid: Bool {
        let allowed = TriageRules.allowed
        return version == 1 && originalTranscript.utf16.count <= 16_000
            && TriageRules.isValid(observations)
            && uncertainties.count <= 30 && uncertainties.allSatisfy { !$0.isEmpty && $0.utf16.count <= 300 }
            && evidence.allSatisfy { key, item in
                (allowed[key] != nil || key == "circulation") && item.source == "model-inferred" && !item.excerpt.isEmpty
                    && item.excerpt.utf16.count <= 1000 && originalTranscript.contains(item.excerpt)
            }
            && (findings ?? []).count <= 100 && Set((findings ?? []).map(\.id)).count == (findings ?? []).count
            && (findings ?? []).allSatisfy { item in
                !item.id.isEmpty && item.id.utf16.count <= 64 && Self.findingKinds.contains(item.kind)
                    && !item.name.isEmpty && item.name.utf16.count <= 100
                    && (item.value?.utf16.count ?? 0) <= 500 && (item.unit?.utf16.count ?? 0) <= 50
                    && ["reported", "observed", "model-inferred"].contains(item.source)
                    && (item.excerpt.map { !$0.isEmpty && $0.utf16.count <= 1000 && originalTranscript.contains($0) } ?? false)
            }
            && AiDevice(rawValue: provenance.device) != nil && !provenance.sttEngine.isEmpty && provenance.sttEngine.utf16.count <= 100
            && !provenance.sttRuntime.isEmpty && provenance.sttRuntime.utf16.count <= 100
            && provenance.extraction.model == "Qwen3-0.6B" && provenance.extraction.execution == "local"
            && provenance.extraction.artifactSha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            && provenance.extraction.revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
            && !provenance.extraction.runtime.isEmpty && provenance.extraction.runtime.utf16.count <= 100
    }

    /// Same text as `SYSTEM_PROMPT` in hub/ai.js. Qwen3-0.6B reliably fills only these four fields; a live test
    /// showed it cannot follow a richer findings schema, so details come from deterministic extractors instead.
    public static let prompt = """
    Classify the rescuer report into 4 fields. Reply ONLY JSON like {"breathing":"abnormal","consciousness":"unresponsive","severeBleeding":"present","walking":"unable"}.
    Allowed values: breathing normal|abnormal|absent|unknown; consciousness alert|unresponsive|unknown; severeBleeding present|absent|unknown; walking able|unable|unknown.
    Decide only from the report; unsure means unknown. Example critical: "nalunod, walang malay, malakas na pagdurugo, hindi makalakad" gives breathing abnormal, consciousness unresponsive, severeBleeding present, walking unable. Example healthy: "awake, breathing normally, no bleeding, can walk" gives breathing normal, consciousness alert, severeBleeding absent, walking able. Hints: "not breathing"/"hindi humihinga"=absent breathing; "difficulty breathing"/"nahihirapan"/"nalunod"/"drowning"=abnormal; "breathing normally"=normal; "unconscious"/"walang malay"/"unresponsive"=unresponsive; "awake"/"gising"/"alert"=alert; "malakas na pagdurugo"/"severe bleeding"/"heavy bleeding"=present; "no bleeding"/"walang dugo"=absent; "cannot walk"/"hindi makalakad"=unable; "can walk"/"nakakalakad"=able.
    """
    public static func validated(generated: String, transcript: String, device: AiDevice, sttEngine: String, artifact: ModelArtifact) throws -> NativeProcessing {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, transcript.utf16.count <= 16_000,
            let first = generated.firstIndex(of: "{"), let last = generated.lastIndex(of: "}"), first <= last,
            let data = generated[first...last].data(using: .utf8),
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QwenFailure.decodeFailed }
        let allowed = ["breathing": ["normal", "abnormal", "absent", "unknown"],
            "consciousness": ["alert", "confused", "unresponsive", "unknown"],
            "severeBleeding": ["present", "absent", "unknown"], "walking": ["able", "unable", "unknown"]]
        let claims = raw["observations"] as? [String: Any] ?? raw
        // The model's quote is not trusted: the transcript must contain a phrase that really means the claimed
        // value, with no contradiction. See ObservationConfirmation (parity-tested against the hub).
        let confirmed = ObservationConfirmation.confirm(
            claims: Dictionary(uniqueKeysWithValues: allowed.keys.map { ($0, claims[$0] as? String ?? "unknown") }), transcript: transcript)
        var observations = confirmed.observations
        let pulse = ObservationConfirmation.circulation(in: transcript)
        observations["circulation"] = pulse.value
        var evidence: [String: Evidence] = confirmed.evidence.mapValues { Evidence(source: "model-inferred", excerpt: $0, contradictory: false) }
        if let quote = pulse.quote { evidence["circulation"] = Evidence(source: "model-inferred", excerpt: quote, contradictory: false) }
        var uncertainty = ["Machine extraction is unverified; qualified assessment required"]
        for key in ObservationConfirmation.order + ["circulation"] where observations[key] == "unknown" { uncertainty.append("\(key) is unknown or lacks source evidence") }
        uncertainty.append(contentsOf: confirmed.warnings.filter { $0.hasPrefix("Contradictory") })
        return NativeProcessing(version: 1, originalTranscript: transcript, observations: observations,
            evidence: evidence, uncertainties: uncertainty,
            provenance: Provenance(device: device.rawValue, sttEngine: sttEngine,
                sttRuntime: ProcessInfo.processInfo.operatingSystemVersionString,
                extraction: Extraction(model: artifact.model, revision: artifact.revision, runtime: "llama.cpp/b6500 CPU",
                    artifactSha256: artifact.sha256, execution: "local")),
            findings: nil)
    }
}
