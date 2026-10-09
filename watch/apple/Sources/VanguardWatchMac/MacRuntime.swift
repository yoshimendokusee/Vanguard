import Foundation
import VanguardApple

/// Hub address and token shared with the delivery hook (which runs off the main actor).
actor HubSettings {
    private(set) var url: URL?
    private(set) var token = ""
    func set(url: URL?, token: String) { self.url = url; self.token = token }
}

struct HostOptions {
    var model = URL(fileURLWithPath: "models/qwen3-0.6b")
    var fresh = false
    var hub: String?
    var submit: String?
    var snapshot: String?
    var route: [String] = []
    var size: String?

    init(_ arguments: [String]) {
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--fresh": fresh = true
            case "--model": i += 1; if i < arguments.count { model = URL(fileURLWithPath: arguments[i]) }
            case "--hub": i += 1; if i < arguments.count { hub = arguments[i] }
            case "--submit": i += 1; if i < arguments.count { submit = arguments[i] }
            case "--snapshot": i += 1; if i < arguments.count { snapshot = arguments[i] }
            case "--route": i += 1; if i < arguments.count { route = arguments[i].split(separator: ",").map(String.init) }
            case "--size": i += 1; if i < arguments.count { size = arguments[i] }
            default: break
            }
            i += 1
        }
        if let env = ProcessInfo.processInfo.environment["VANGUARD_MODEL_DIR"] { model = URL(fileURLWithPath: env) }
    }
}

/// Assembles the real services (SQLite store, local Qwen, deterministic triage, hub delivery) behind the Watch screens.
/// Everything is real except the device: this is a Mac, so it proves behavior, not Apple Watch hardware.
@MainActor
final class MacRuntime: ObservableObject {
    let controller: VoiceReportController
    let workflow: NativeWorkflow
    let hub = HubSettings()
    let storeDirectory: URL
    private let isThrowaway: Bool
    @Published var hubURL: String
    @Published var token = ""
    @Published var syncMessage = "Hub not configured: reports stay saved on this Mac"
    @Published var modelStatus = "Checking the local model…"

    init(options: HostOptions) throws {
        isThrowaway = options.fresh || options.snapshot != nil
        storeDirectory = options.fresh
            ? FileManager.default.temporaryDirectory.appendingPathComponent("vanguard-watch-mac-" + UUID().uuidString)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VanguardWatchMac-dev")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = try NativeStore(file: storeDirectory.appendingPathComponent("vanguard-native.sqlite"))
        let workflow = NativeWorkflow(store: store, engine: QwenEngine(directory: options.model))
        self.workflow = workflow
        // Throwaway (fresh) and snapshot runs never deliver anywhere unless a hub is given explicitly.
        hubURL = options.hub ?? ((options.fresh || options.snapshot != nil) ? "" : UserDefaults.standard.string(forKey: "vgmac-hub") ?? "")
        let box = hub
        let hooks = VoiceReportHooks(
            transcribeAndProcess: { capture in
                // Typed text goes straight to extraction; audio is transcribed on this Mac, on-device.
                if capture.transcript != nil { _ = try await workflow.process(capture, device: .appleWatch) }
                else {
                    // Speech permission needs an .app bundle (scripts/mac-host.sh); a bare executable would be killed by macOS.
                    guard Bundle.main.bundleURL.pathExtension == "app" else { throw TranscriptionFailure.permissionRequired }
                    _ = try await workflow.processAudio(capture)
                }
                return .processed
            },
            syncHospital: {
                guard let url = await box.url else { return }
                _ = try? await workflow.sync(to: url, token: await box.token)
            })
        controller = VoiceReportController(recorder: MacMicrophone(), workflow: workflow, hooks: hooks,
                                           deviceID: "MAC-DEV-HOST-" + (UserDefaults.standard.string(forKey: "vgmac-id") ?? Self.newID()),
                                           device: .appleWatch, audioDirectory: storeDirectory.appendingPathComponent("Recordings"))
        applyHub()
        Task { await checkModel(options.model) }
    }

    private static func newID() -> String {
        let id = UUID().uuidString.lowercased(); UserDefaults.standard.set(id, forKey: "vgmac-id"); return id
    }

    func applyHub() {
        let trimmed = hubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isThrowaway { UserDefaults.standard.set(trimmed, forKey: "vgmac-hub") }
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        syncMessage = url == nil ? "Hub not configured: reports stay saved on this Mac" : "Delivering to \(trimmed)"
        let box = hub, token = token
        Task { await box.set(url: url, token: token) }
    }

    func syncNow() async {
        applyHub()
        guard let url = await hub.url else { return }
        do { let sent = try await workflow.sync(to: url, token: token); syncMessage = "Hospital acknowledged \(sent) new report(s)" }
        catch { syncMessage = "Not delivered, reports are kept and will retry (\(error))" }
        await controller.loadRecents()
    }

    private func checkModel(_ directory: URL) async {
        do { _ = try ModelArtifact.verify(directory: directory); modelStatus = "Local Qwen3-0.6B verified (SHA-256). Loads on first use." }
        catch { modelStatus = "Model not found at \(directory.path). Set --model or VANGUARD_MODEL_DIR." }
    }
}
