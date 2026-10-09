#if os(iOS) || os(macOS)
import Foundation
import Speech

public struct LocalTranscript: Sendable {
    public let originalText: String
    public let segmentConfidences: [Float]
    public let engine: String
    public let runtime: String
}

public enum TranscriptionFailure: Error {
    case permissionRequired, onDeviceUnavailable, busy, empty, timeout
}

/// iPhone fallback only. Speech.framework is absent from the watchOS 27 SDK.
@MainActor
public final class OnDeviceTranscriber {
    private var task: SFSpeechRecognitionTask?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<LocalTranscript, Error>?

    public init() {}

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public func transcribe(file: URL, locale: Locale) async throws -> LocalTranscript {
        guard continuation == nil else { throw TranscriptionFailure.busy }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionFailure.permissionRequired
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionFailure.onDeviceUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task = recognizer.recognitionTask(with: request) { result, error in
                    Task { @MainActor in
                        if let result, result.isFinal {
                            let text = result.bestTranscription.formattedString
                            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                self.finish(.failure(TranscriptionFailure.empty))
                                return
                            }
                            self.finish(.success(LocalTranscript(originalText: text,
                                segmentConfidences: result.bestTranscription.segments.map(\.confidence),
                                engine: "SFSpeechRecognizer/on-device",
                                runtime: ProcessInfo.processInfo.operatingSystemVersionString)))
                        } else if let error { self.finish(.failure(error)) }
                    }
                }
                deadline = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: 55_000_000_000)
                        finish(.failure(TranscriptionFailure.timeout))
                    } catch { /* Completed or cancelled before the deadline. */ }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<LocalTranscript, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result)
    }
}
#endif
