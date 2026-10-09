#if os(iOS) || os(macOS)
import Foundation
import Speech

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

#if os(iOS) || os(macOS)
/// Picks the best on-device transcript across locales. Emergency reports mix English and Filipino (Taglish) and a
/// single recognizer handles only one language, so each locale that supports on-device recognition is tried and the
/// one the recognizer is most confident about wins. Cloud recognition is never used. Code-switching inside one
/// sentence can still be transcribed imperfectly: the person reviews the transcript, which stays correctable.
public enum LocaleSelection {
    public static let defaultLocales = [Locale(identifier: "en-US"), Locale(identifier: "fil-PH")]

    public static func meanConfidence(_ transcript: LocalTranscript) -> Float {
        let scores = transcript.segmentConfidences.filter { $0 > 0 }   // 0 means "not provided" for partial segments
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Float(scores.count)
    }

    /// `transcribe` runs one on-device pass. Locales that are unavailable or return nothing are skipped.
    /// Throws the last failure only when no locale produced text.
    public static func best(locales: [Locale], transcribe: (Locale) async throws -> LocalTranscript) async throws -> (transcript: LocalTranscript, locale: Locale) {
        var best: (LocalTranscript, Locale, Float)?
        var lastError: Error = TranscriptionFailure.onDeviceUnavailable
        for locale in locales {
            try Task.checkCancellation()
            do {
                let result = try await transcribe(locale)
                let score = meanConfidence(result)
                if best == nil || score > best!.2 { best = (result, locale, score) }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        guard let best else { throw lastError }
        return (best.0, best.1)
    }
}
#endif
