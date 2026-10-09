import Foundation

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
        guard transcript.count <= Self.maxTranscript else {
            throw AiContractError.transcriptTooLong(max: Self.maxTranscript)
        }
        self.transcript = transcript
        self.device = device.rawValue
        self.sttEngine = sttEngine
        self.sttRuntime = sttRuntime
    }

    /// Lenient decode: unknown device strings keep working via the hub fallback.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        transcript = try box.decode(String.self, forKey: .transcript)
        device = AiDevice(safe: (try? box.decode(String.self, forKey: .device)) ?? "").rawValue
        sttEngine = try? box.decode(String.self, forKey: .sttEngine)
        sttRuntime = try? box.decode(String.self, forKey: .sttRuntime)
    }
}

public struct AiStatus: Codable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case breathing, consciousness, severeBleeding, walking
    }

    /// Missing keys decode as unknown so a newer hub never breaks this client.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        breathing = (try? box.decode(String.self, forKey: .breathing)) ?? "unknown"
        consciousness = (try? box.decode(String.self, forKey: .consciousness)) ?? "unknown"
        severeBleeding = (try? box.decode(String.self, forKey: .severeBleeding)) ?? "unknown"
        walking = (try? box.decode(String.self, forKey: .walking)) ?? "unknown"
    }
}

public struct AiProvenance: Codable, Sendable {
    public let device: String
    public let sttEngine: String
    public let sttRuntime: String
}

public struct AiProcessing: Codable, Sendable {
    public let version: Int
    public let originalTranscript: String
    public let observations: AiObservations
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
