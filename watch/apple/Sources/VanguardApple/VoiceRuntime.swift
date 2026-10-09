#if os(iOS) || os(watchOS)
import Foundation

/// Assembles the real services for the voice-report app: SQLite store, local Qwen, the paired-device relay,
/// the microphone and the controller. Offline-first: nothing here needs a network to record or process.
@MainActor
public final class VoiceRuntime: ObservableObject {
    public let controller: VoiceReportController
    public let workflow: NativeWorkflow
    private let relay: WatchRelay
    private let deviceID: String

    public init() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let store = try NativeStore(file: documents.appendingPathComponent("vanguard-native.sqlite"))
        let model = Bundle.main.url(forResource: "qwen3-0.6b", withExtension: nil) ?? Bundle.main.bundleURL.appendingPathComponent("qwen3-0.6b")
        let workflow = NativeWorkflow(store: store, engine: QwenEngine(directory: model))
        let relay = WatchRelay(workflow: workflow)
        let defaults = UserDefaults.standard
        #if os(watchOS)
        let prefix = "APPLE-WATCH-", device = AiDevice.appleWatch
        #else
        let prefix = "IPHONE-", device = AiDevice.iphone
        #endif
        let id = defaults.string(forKey: "vanguard-device") ?? prefix + UUID().uuidString.lowercased()
        defaults.set(id, forKey: "vanguard-device")
        self.workflow = workflow; self.relay = relay; deviceID = id

        let hooks = VoiceReportHooks(
            transcribeAndProcess: { capture in try await Self.transcribe(capture, store: store, workflow: workflow, relay: relay) },
            syncHospital: { await Self.sync(workflow) })
        controller = VoiceReportController(recorder: MicrophoneRecorder(), workflow: workflow, hooks: hooks, deviceID: id, device: device,
                                           audioDirectory: documents.appendingPathComponent("Recordings"))
        let controller = self.controller
        relay.onResult = { id in Task { @MainActor in await controller.resultArrived(id) } }
        relay.onChange = { _ in Task { await Self.sync(workflow) } }
    }

    /// Process audio on the Watch first. If local transcription or extraction fails, the saved recording is offered
    /// to the paired iPhone as a fallback and remains pending until its result arrives.
    private static func transcribe(_ capture: NativeCapture, store: NativeStore, workflow: NativeWorkflow, relay: WatchRelay) async throws -> TranscriptionOutcome {
        if try await store.processing(id: capture.id) != nil { return .processed }
        #if os(watchOS)
        do {
            _ = try await workflow.processAudio(capture)
            return .processed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            do { try await relay.offer(capture) } catch { return .pending }
        }
        for _ in 0..<90 {
            try Task.checkCancellation()
            if try await store.processing(id: capture.id) != nil { return .processed }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return .pending
        #else
        if capture.transcript != nil { _ = try await workflow.process(capture, device: .iphone) } else { _ = try await workflow.processAudio(capture) }
        return .processed
        #endif
    }

    /// Uses the saved hub address and token; with none configured, reports simply stay queued on the device.
    private static func sync(_ workflow: NativeWorkflow) async {
        let defaults = UserDefaults.standard
        guard let text = defaults.string(forKey: "vanguard-hub") ?? (try? AppConfiguration.load())?.hubURL.absoluteString,
              let url = try? HubEndpoint(text).url else { return }
        _ = try? await workflow.sync(to: url, token: HubCredential.read())
    }
}
#endif
