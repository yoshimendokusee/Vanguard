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
            relay?.onChange = { [weak self] message in Task { @MainActor in self?.status = message } }
            let defaults = UserDefaults.standard
            #if os(watchOS)
            let prefix = "APPLE-WATCH-"
            #else
            let prefix = "IPHONE-"
            #endif
            deviceID = defaults.string(forKey: "vanguard-device") ?? prefix + UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: "vanguard-device")
            // A hub URL typed in the app wins; otherwise use the build-time HUB_URL from Info.plist.
            hub = defaults.string(forKey: "vanguard-hub") ?? ((try? AppConfiguration.load())?.hubURL.absoluteString ?? "")
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
                let processing = try await workflow.process(capture, device: device)
                result = processing.observations.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value) (unverified)" }.joined(separator: "\n")
                    + "\n" + processing.uncertainties.joined(separator: "\n")
                status = "Extraction saved; provisional Unassessed — verify clinically"
                await sync()
            } catch {
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
                await sync()
            } catch { status = "Recovery interrupted; pending input retained" }
        }
    }
    func cancel() { task?.cancel(); status = "Cancelling; original remains in SQLite" }
    func sync() async {
        guard let workflow, let url = URL(string: hub), ["http", "https"].contains(url.scheme), url.host != nil else { return }
        UserDefaults.standard.set(hub, forKey: "vanguard-hub")
        do { let count = try await workflow.sync(to: url); if count > 0 { status = "\(count) hospital LAN receipts acknowledged; clinical verification pending" } }
        catch { status = "Hospital unavailable; local outbox retained" }
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
        _ = try await workflow.processAudio(capture)
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
                let processing = try await workflow.process(capture, device: device)
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
                TextField("Original patient report", text: $model.transcript, axis: .vertical).accessibilityLabel("Original patient transcript")
                Button("Save and extract locally") { model.save() }.disabled(model.busy || model.recording)
                Button(model.recording ? "Stop and save audio" : "Record audio") { model.toggleRecording() }.disabled(model.busy)
                Text(model.status).font(.caption).accessibilityIdentifier("qwen-status")
                if !model.result.isEmpty { Text(model.result).font(.caption) }
                Button("Retry pending work") { model.recover() }.disabled(model.busy || model.recording)
                if model.busy { Button("Cancel") { model.cancel() } }
                TextField("Hospital LAN URL", text: $model.hub).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Retry hospital relay") { Task { await model.sync() } }
            }.padding()
        }.onChange(of: phase) { _, state in if state == .active { model.recover() } }
    }
}
