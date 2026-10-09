import SwiftUI
import AppKit
import VanguardApple

/// Development host for the Vanguard Apple Watch UI: the exact SwiftUI screens and controller the Watch app uses,
/// wired to the real local pipeline, inside a Mac window. It is a test bench, not a product, and not Apple hardware.
@main
struct VanguardWatchMacApp: App {
    @State private var runtime: Result<MacRuntime, Error>
    private let options: HostOptions

    init() {
        let options = HostOptions(CommandLine.arguments)
        self.options = options
        _runtime = State(initialValue: Result { try MacRuntime(options: options) })
    }

    var body: some Scene {
        WindowGroup("Vanguard Watch · Mac development host") {
            switch runtime {
            case .success(let runtime): HostView(runtime: runtime, options: options)
            case .failure(let error): Text("Could not open local storage: \(error.localizedDescription)").padding(40)
            }
        }
        .windowResizability(.contentSize)
    }
}

struct WatchSize: Identifiable, Hashable {
    let name: String; let width: CGFloat; let height: CGFloat; var id: String { name }
    static let all = [WatchSize(name: "41 mm", width: 176, height: 215), WatchSize(name: "45 mm", width: 198, height: 242), WatchSize(name: "49 mm Ultra", width: 205, height: 251)]
}

struct HostView: View {
    @ObservedObject var runtime: MacRuntime
    let options: HostOptions
    @State private var size: WatchSize
    init(runtime: MacRuntime, options: HostOptions) {
        self.runtime = runtime; self.options = options
        _size = State(initialValue: WatchSize.all.first { $0.name.hasPrefix(options.size ?? "45") } ?? WatchSize.all[1])
    }
    @State private var typed = ""
    private let zoom: CGFloat = 1.9

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 10) {
                WatchRootView(controller: runtime.controller, startRoutes: options.route)
                    .frame(width: size.width, height: size.height)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 48))
                    .overlay(RoundedRectangle(cornerRadius: 48).stroke(Color(white: 0.28), lineWidth: 4))
                    .environment(\.colorScheme, .dark)
                    .scaleEffect(zoom)
                    .frame(width: size.width * zoom + 20, height: size.height * zoom + 20)
                Picker("Watch size", selection: $size) { ForEach(WatchSize.all) { Text($0.name).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 300)
            }
            controls.frame(width: 340)
        }
        .padding(24)
        .task {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let text = options.submit { await runtime.controller.submitText(text) }
            if let path = options.snapshot { await Self.snapshot(to: path, runtime: runtime) }
        }
    }

    /// Development aid: writes the real window contents to a PNG (no screen-recording permission needed) and exits.
    @MainActor static func snapshot(to path: String, runtime: MacRuntime) async {
        for _ in 0..<120 {   // wait until processing and delivery settled
            let state = runtime.controller.state
            if state == .delivered || state == .idle || state == .ready || state == .queuedForDelivery { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await runtime.controller.loadRecents()
        FileHandle.standardError.write(Data("SNAP state=\(runtime.controller.state) recents=\(runtime.controller.recents.map { "\($0.provisional?.triage.rawValue ?? "nil")/\($0.delivery.rawValue)" })\n".utf8))
        guard let view = NSApplication.shared.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Development host").font(.title2.bold())
            Text("These are the real Watch screens and the real pipeline: local Qwen, deterministic triage, SQLite, hospital delivery. It runs on a Mac, so it says nothing about Apple Watch hardware, and the Mac's own speech recognition does the transcribing.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("Local AI") { Text(runtime.modelStatus).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Hospital hub") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("http://127.0.0.1:3010", text: $runtime.hubURL).textFieldStyle(.roundedBorder)
                    SecureField("Access token (optional)", text: $runtime.token).textFieldStyle(.roundedBorder)
                    HStack { Button("Apply") { runtime.applyHub() }; Button("Deliver now") { Task { await runtime.syncNow() } } }
                    Text(runtime.syncMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            GroupBox("Try it without speaking") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Type a synthetic report…", text: $typed, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                    Button("Submit as a typed report") { let text = typed; typed = ""; Task { await runtime.controller.submitText(text) } }
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Same pipeline as a recording, minus the microphone. Synthetic data only.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Data folder: \(runtime.storeDirectory.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
