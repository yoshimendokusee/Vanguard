import SwiftUI
import VanguardApple
import AVFoundation

@main
struct VanguardApp: App {
    @StateObject private var model = CaptureModel()
    var body: some Scene { WindowGroup { CaptureView(model: model) } }
}

@MainActor
final class CaptureModel: ObservableObject {
    @Published var transcript = ""
    @Published var status = "Opening local storage…"
    @Published var result = ""
    @Published var busy = false
    @Published var recording = false
    @Published var hub = ""
    @Published var hubToken = ""
    @Published var localAI: AiReadiness = .initializing
    @Published var lanStatus = "Not configured"
    @Published var deviceIdentity = ""
    private var syncing = false
    private var workflow: NativeWorkflow?
    private var relay: WatchRelay?
    private var task: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var audioCapture: NativeCapture?
    private var deviceID = ""
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        do {
            let store = try NativeStore(file: documents.appendingPathComponent("vanguard-native.sqlite"))
            let directory = Bundle.main.url(forResource: "qwen3-0.6b", withExtension: nil)
                ?? Bundle.main.bundleURL.appendingPathComponent("qwen3-0.6b")
            let engine = QwenEngine(directory: directory)
            let workflow = NativeWorkflow(store: store, engine: engine)
            self.workflow = workflow
            relay = WatchRelay(workflow: workflow)
            relay?.onChange = { [weak self] message in Task { @MainActor in self?.status = message; await self?.sync() } }
            let defaults = UserDefaults.standard
            #if os(watchOS)
            let prefix = "APPLE-WATCH-"
            #else
            let prefix = "IPHONE-"
            #endif
            deviceID = defaults.string(forKey: "vanguard-device") ?? prefix + UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: "vanguard-device")
            deviceIdentity = deviceID
            // Saved pairing wins over public build-time configuration.
            hub = defaults.string(forKey: "vanguard-hub") ?? ((try? AppConfiguration.load())?.hubURL.absoluteString ?? "")
            hubToken = HubCredential.read()
            status = "Capture ready; model loads on first request"
            if ProcessInfo.processInfo.arguments.contains("--qwen-smoke") { smoke() }
            else { recover() }
        } catch { status = "Local storage/model unavailable: \(error)" }
    }
    private var device: AiDevice {
        #if os(watchOS)
        return .appleWatch
        #else
        return .iphone
        #endif
    }
    private func now() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    func save() {
        guard !busy, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let workflow else { return }
        let original = transcript
        busy = true
        task = Task {
            defer { busy = false }
            var savedCapture: NativeCapture?
            do {
                let capture = try await workflow.store.capture(watchID: deviceID, transcript: original)
                savedCapture = capture
                status = "Original saved locally; extracting…"
                localAI = .modelLoading
                let processing = try await workflow.process(capture, device: device)
                localAI = await workflow.engine.state
                result = processing.observations.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value) (unverified)" }.joined(separator: "\n")
                    + "\n" + processing.uncertainties.joined(separator: "\n")
                status = "Extraction saved; provisional Unassessed — verify clinically"
                await sync()
            } catch {
                localAI = await workflow.engine.state
                await sync()
                status = savedCapture == nil ? "Capture could not be saved; retry: \(error)"
                    : "Original retained; local inference failed: \(error)"
                #if os(watchOS)
                if let capture = savedCapture { do { try relay?.offer(capture); status += "; queued for iPhone" } catch { status += "; fallback pending" } }
                #endif
            }
        }
    }
    func recover() {
        guard !busy, let workflow else { return }
        relay?.retry()
        busy = true
        task = Task {
            defer { busy = false }
            do {
                localAI = .modelLoading
                do { localAI = try await workflow.engine.readiness() }
                catch { localAI = await workflow.engine.state }
                for capture in try await workflow.store.captures(pendingOnly: true) {
                    try Task.checkCancellation()
                    do {
                        if capture.transcript != nil { _ = try await workflow.process(capture, device: device) }
                        else {
                            #if os(iOS)
                            try await transcribe(capture)
                            #else
                            try relay?.offer(capture)
                            #endif
                        }
                    } catch {
                        #if os(watchOS)
                        try? relay?.offer(capture)
                        #endif
                        status = "Pending input retained; retry or use paired iPhone"
                    }
                }
                localAI = await workflow.engine.state
                await sync()
            } catch { status = "Recovery interrupted; pending input retained" }
        }
    }
    func cancel() { task?.cancel(); status = "Cancelling; original remains in SQLite" }
    func sync() async {
        guard let workflow, !syncing else { return }
        guard !hub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { lanStatus = "Not configured; reports retained"; return }
        syncing = true
        defer { syncing = false }
        do {
            let endpoint = try HubEndpoint(hub)
            try HubCredential.save(hubToken)
            UserDefaults.standard.set(endpoint.url.absoluteString, forKey: "vanguard-hub")
            lanStatus = "Connecting…"
            let count = try await workflow.sync(to: endpoint.url, token: hubToken)
            lanStatus = "Connected; \(count) hospital receipts acknowledged"
        } catch { lanStatus = "Disconnected or invalid configuration; outbox retained: \(error)" }
    }
    func toggleRecording() {
        if recording {
            recorder?.stop(); recording = false
            guard let capture = audioCapture, let workflow else { return }
            busy = true
            task = Task {
                defer { busy = false }
                do {
                    try await workflow.store.save(capture)
                    status = "Audio saved locally; transcription pending"
                    #if os(iOS)
                    try await transcribe(capture)
                    #else
                    try relay?.offer(capture)
                    status = "Audio queued for iPhone. Offline Watch speech recognition is not implemented"
                    #endif
                } catch { status = "Audio retained; transcription/fallback unavailable" }
            }
        } else {
            busy = true
            AVAudioApplication.requestRecordPermission { [weak self] allowed in
                Task { @MainActor in
                    guard let self else { return }
                    defer { self.busy = false }
                    guard allowed else { self.status = "Microphone permission required"; return }
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
                        try AVAudioSession.sharedInstance().setActive(true)
                        let file = self.documents.appendingPathComponent(UUID().uuidString + ".m4a")
                        let recorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue])
                        guard let workflow = self.workflow else { throw NativeStoreFailure.unavailable }
                        let capture = try await workflow.store.capture(watchID: self.deviceID, transcript: nil, audioPath: file.path)
                        self.audioCapture = capture
                        guard recorder.record() else { throw NativeStoreFailure.unavailable }
                        self.recorder = recorder; self.audioURL = file; self.recording = true; self.status = "Recording locally…"
                    } catch { self.status = "Recording unavailable" }
                }
            }
        }
    }
    #if os(iOS)
    private func transcribe(_ capture: NativeCapture) async throws {
        guard let workflow else { throw NativeStoreFailure.unavailable }
        localAI = .modelLoading
        _ = try await workflow.processAudio(capture)
        localAI = await workflow.engine.state
        await sync()
        status = "On-device speech and Qwen output persisted; clinical verification pending"
    }
    #endif
    private func smoke() {
        guard let workflow else { return }
        busy = true
        task = Task {
            defer { busy = false }
            do {
                let echo = try await workflow.engine.generate(system: "You are Qwen3-0.6B inside Vanguard.",
                    prompt: "Identify yourself as Qwen3-0.6B and respond with the verification marker VANGUARD_QWEN_OK.", maxTokens: 96)
                let capture = NativeCapture(watchID: deviceID, createdAt: now(), transcript: "Synthetic patient is awake, breathing normally, no severe bleeding, can walk.")
                localAI = .modelLoading
                let processing = try await workflow.process(capture, device: device)
                localAI = await workflow.engine.state
                guard processing.originalTranscript == capture.transcript,
                    try await workflow.store.processing(id: capture.id) != nil else { throw NativeStoreFailure.unavailable }
                let evidence: [String: Any] = ["status": "PASS", "platform": device.rawValue,
                    "generated": try JSONSerialization.jsonObject(with: JSONEncoder().encode(echo)),
                    "captureID": capture.id, "originalPreserved": true, "sqlitePersisted": true,
                    "hardwareVerified": false]
                try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: documents.appendingPathComponent("qwen-smoke.json"), options: .atomic)
                status = "Synthetic native inference and persistence smoke passed"; result = echo.text
            } catch {
                let evidence = ["status": "FAIL", "platform": device.rawValue, "error": String(describing: error)]
                try? JSONEncoder().encode(evidence).write(to: documents.appendingPathComponent("qwen-smoke.json"), options: .atomic)
                status = "Native smoke failed: \(error)"
            }
        }
    }
}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vanguard").font(.headline)
                Text("Local Qwen extraction · provisional").font(.caption)
                Text("Local AI: \(model.localAI.rawValue)").font(.caption).accessibilityIdentifier("local-ai-state")
                Text("LAN Hub: \(model.lanStatus)").font(.caption).accessibilityIdentifier("lan-state")
                TextField("Original patient report", text: $model.transcript, axis: .vertical).accessibilityLabel("Original patient transcript")
                Button("Save and extract locally") { model.save() }.disabled(model.busy || model.recording)
                Button(model.recording ? "Stop and save audio" : "Record audio") { model.toggleRecording() }.disabled(model.busy)
                Text(model.status).font(.caption).accessibilityIdentifier("qwen-status")
                if !model.result.isEmpty { Text(model.result).font(.caption) }
                Button("Retry pending work") { model.recover() }.disabled(model.busy || model.recording)
                if model.busy { Button("Cancel") { model.cancel() } }
                TextField("Hospital LAN URL", text: $model.hub).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Hospital access token", text: $model.hubToken)
                Text("Device: \(model.deviceIdentity)").font(.caption)
                Button("Retry hospital relay") { Task { await model.sync() } }
            }.padding()
        }.task {
            // Bounded foreground reconnection; retained rows survive suspension/restart.
            for attempt in 0..<3 {
                do { try await Task.sleep(for: .seconds(30 * (1 << attempt))) } catch { return }
                guard phase == .active else { return }
                await model.sync()
            }
        }.onChange(of: phase) { _, state in if state == .active { model.recover() } }
    }
}
