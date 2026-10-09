import Foundation

public enum AiReadiness: String, Codable, Sendable {
    case initializing = "INITIALIZING", modelMissing = "MODEL_MISSING", modelDownloading = "MODEL_DOWNLOADING"
    case modelLoading = "MODEL_LOADING", ready = "READY", unavailable = "UNAVAILABLE", error = "ERROR"
}

/// Shared device identity and optional hospital preview contract.
/// Native capture uses QwenEngine and NativeWorkflow; hospital previews use these
/// request/response types. Capture never waits on hospital AI. See docs/ai-contract.md.
public enum AiDevice: String, Codable, Sendable, CaseIterable {
    case hospitalBrowser = "hospital-browser"
    case iphone
    case appleWatch = "apple-watch"
    case wearOs = "wear-os"

    /// Unknown values fall back to the hospital browser (hub behavior).
    public init(safe rawValue: String) {
        self = AiDevice(rawValue: rawValue) ?? .hospitalBrowser
    }
}

public enum AiContractError: Error, Sendable {
    case emptyTranscript
    case transcriptTooLong(max: Int)
    case invalidProvenance
}

public struct AiRequest: Codable, Sendable {
    public static let maxTranscript = 4000
    public static let extractPath = "/api/ai/extract"
    public static let assistPath = "/api/ai/triage-assist"
    public static let statusPath = "/api/ai/status"

    public let transcript: String
    public let device: String
    public let sttEngine: String?
    public let sttRuntime: String?

    private enum CodingKeys: String, CodingKey {
        case transcript, device, sttEngine, sttRuntime
    }

    public init(transcript: String, device: AiDevice, sttEngine: String? = nil, sttRuntime: String? = nil) throws {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AiContractError.emptyTranscript }
        guard transcript.utf16.count <= Self.maxTranscript else {
            throw AiContractError.transcriptTooLong(max: Self.maxTranscript)
        }
        guard [sttEngine, sttRuntime].allSatisfy({ $0 == nil || $0!.utf16.count <= 100 }) else { throw AiContractError.invalidProvenance }
        self.transcript = transcript
        self.device = device.rawValue
        self.sttEngine = sttEngine
        self.sttRuntime = sttRuntime
    }

    /// Lenient decode: unknown device strings keep working via the hub fallback.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(transcript: box.decode(String.self, forKey: .transcript),
            device: AiDevice(safe: (try? box.decode(String.self, forKey: .device)) ?? ""),
            sttEngine: try? box.decode(String.self, forKey: .sttEngine),
            sttRuntime: try? box.decode(String.self, forKey: .sttRuntime))
    }
}

public struct AiStatus: Codable, Sendable {
    public let contractVersion: Int?
    public let state: AiReadiness?
    public let ok: Bool
    public let available: Bool
    public let model: String
    public let modelAvailable: Bool?
    public let error: String?
    public let promptVersion: String?
    public let maxTranscript: Int?
}

public struct AiObservations: Codable, Sendable {
    public let breathing: String
    public let consciousness: String
    public let severeBleeding: String
    public let walking: String
    public let circulation: String

    private enum CodingKeys: String, CodingKey {
        case breathing, consciousness, severeBleeding, walking, circulation
    }

    /// Missing keys decode as unknown so a newer hub never breaks this client.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func safe(_ key: CodingKeys, _ allowed: [String]) -> String {
            let value = (try? box.decode(String.self, forKey: key)) ?? "unknown"
            return allowed.contains(value) ? value : "unknown"
        }
        breathing = safe(.breathing, ["normal", "abnormal", "absent", "unknown"])
        consciousness = safe(.consciousness, ["alert", "confused", "unresponsive", "unknown"])
        severeBleeding = safe(.severeBleeding, ["present", "absent", "unknown"])
        walking = safe(.walking, ["able", "unable", "unknown"])
        circulation = safe(.circulation, ["present", "absent", "unknown"])
    }
}

public struct AiProvenance: Codable, Sendable {
    public let device: String
    public let sttEngine: String
    public let sttRuntime: String
    public let extraction: NativeProcessing.Extraction?
}

public struct AiProcessing: Codable, Sendable {
    public let version: Int
    public let originalTranscript: String
    public let observations: AiObservations
    public let evidence: [String: NativeProcessing.Evidence]?
    public let uncertainties: [String]
    public let provenance: AiProvenance
}

public struct AiProvisional: Codable, Sendable {
    public let triage: String
    public let reason: String
    public let requiresVerification: Bool
    public let advisoryOnly: Bool?
}

public struct AiDraft: Codable, Sendable {
    public let injuries: String
    public let triage: String
    public let provisional: Bool
}

public struct AiExtractionResult: Codable, Sendable {
    public let contractVersion: Int?
    public let requestId: String?
    public let ok: Bool
    public let processing: AiProcessing
    public let evidence: [String: String?]
    public let warnings: [String]
    public let provisional: AiProvisional
    public let draft: AiDraft?
    public let model: String?
    public let promptVersion: String?

    public func evidence(for key: String) -> String? {
        evidence[key] ?? nil
    }
}

public struct AiErrorResponse: Codable, Sendable {
    public let ok: Bool
    public let error: String
    public let message: String?
}
