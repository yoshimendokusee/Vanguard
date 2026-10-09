import Foundation

public struct PendingCapture: Sendable {
    public let captureID: String
    public let watchID: String
    public let createdAt: String
    public let audioFile: URL

    public init(captureID: String, watchID: String, createdAt: String, audioFile: URL) {
        self.captureID = captureID
        self.watchID = watchID
        self.createdAt = createdAt
        self.audioFile = audioFile
    }
}

// NativeStore preserves transcript, extraction provenance/uncertainty and the
// pending hospital outbox atomically.
public protocol FallbackRepository: Sendable {
    func pendingCaptures() async throws -> [PendingCapture]
    func commitProcessed(capture: PendingCapture, transcript: String, processingJSON: Data) async throws
}

public protocol OfflineCaptureProcessor: Sendable {
    func process(_ capture: PendingCapture) async throws -> (transcript: String, processingJSON: Data)
}

public struct FallbackAttempt: Sendable {
    public let captureID: String
    public let committed: Bool
}

/// Call on durable receipt, app activation and retry wakeups. Failed jobs stay
/// pending in the repository; a successful relay receipt is never hospital delivery.
public actor FallbackProcessor {
    private let repository: any FallbackRepository
    private let processor: any OfflineCaptureProcessor
    private var running = false

    public init(repository: any FallbackRepository, processor: any OfflineCaptureProcessor) {
        self.repository = repository
        self.processor = processor
    }

    public func recover() async throws -> [FallbackAttempt] {
        guard !running else { return [] }
        running = true
        defer { running = false }
        var outcomes: [FallbackAttempt] = []
        for capture in try await repository.pendingCaptures() {
            try Task.checkCancellation()
            do {
                let output = try await processor.process(capture)
                try await repository.commitProcessed(capture: capture,
                    transcript: output.transcript, processingJSON: output.processingJSON)
                outcomes.append(FallbackAttempt(captureID: capture.captureID, committed: true))
            } catch {
                if error is CancellationError { throw error }
                outcomes.append(FallbackAttempt(captureID: capture.captureID, committed: false))
            }
        }
        return outcomes
    }
}
