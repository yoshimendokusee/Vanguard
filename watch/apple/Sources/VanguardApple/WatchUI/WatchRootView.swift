import SwiftUI

/// The Apple Watch app. A thin view over `VoiceReportController`: all behavior (recording, processing,
/// triage, delivery) lives in the controller and the store, so screens can be left and re-entered safely.
public struct WatchRootView: View {
    enum Route: Hashable { case transcript, triage, details, result, recent, connection }
    enum Editor: Identifiable { case transcript; var id: Int { 0 } }

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: VoiceReportController
    @State private var path: [Route] = []
    @State private var editor: Editor?
    private let pinnedStart: Bool

    /// `startRoutes` opens the app already on a pushed screen (by name). Used by the Mac development host to photograph screens.
    public init(controller: VoiceReportController, startRoutes: [String] = []) {
        self.controller = controller
        let known: [String: Route] = ["transcript": .transcript, "triage": .triage, "details": .details, "result": .result, "recent": .recent, "connection": .connection]
        _path = State(initialValue: startRoutes.compactMap { known[$0] }); pinnedStart = !startRoutes.isEmpty
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView { rootContent.padding(.horizontal, 4) }
                .scrollIndicators(.hidden)
                .modifier(WatchChrome())
                .navigationTitle("WristCue")    // watchOS draws the title in the tint color, teal here, with the system clock
                #if !os(watchOS)
                .toolbar(.hidden)
                #endif
                .navigationDestination(for: Route.self) { route in PushedScreen(controller: controller, route: route, path: $path, editor: $editor)
                        .modifier(WatchChrome(onBack: { if !path.isEmpty { path.removeLast() } })) }
        }
        .tint(VanguardPalette.accent)
        .sheet(item: $editor) { which in
            switch which {
            case .transcript: TranscriptEditor(original: controller.snapshot?.currentTranscript ?? "") { text in Task { await controller.correctTranscript(text) } }
            }
        }
        .onChange(of: controller.preparedReportID) { _, id in
            if id != nil, !pinnedStart { path = [.triage] }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await controller.loadRecents(); await controller.recoverPendingWork()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await controller.sendNowIfPending()
            }
        }
    }

    // MARK: Root (home / recording / processing / failure)

    @ViewBuilder private var rootContent: some View {
        switch controller.state {
        case .idle, .ready, .queuedForDelivery, .delivering, .delivered:
            HomeScreen(recentCount: controller.recents.count, onRecord: { Task { await controller.startRecording() } }, onRecent: { path.append(.recent) })
            CapsuleButton(title: "Hospital connection", style: .secondary) { path.append(.connection) }
        case .requestingPermission, .recording, .savingRecording:
            RecordingScreen(elapsed: controller.elapsed, levels: controller.levels, onStop: { Task { await controller.stopRecording() } })
        case .transcribing:
            TranscribingScreen(headline: "Transcribing…", detail: transcribingDetail)
        case .extracting, .evaluatingTriage, .preparingReport:
            TranscribingScreen(headline: "Preparing report…", detail: "Processing locally, offline")
        case .failed(let failure):
            failureScreen(failure)
        }
    }

    private var transcribingDetail: String {
        #if os(watchOS)
        "On this Watch, offline; iPhone is optional"
        #else
        "Processing on device"
        #endif
    }

    @ViewBuilder private func failureScreen(_ failure: VoiceReportFailure) -> some View {
        switch failure {
        case .permissionDenied:
            FailureScreen(title: "Microphone is off", message: controller.message, actionTitle: "Try again", onAction: { Task { await controller.startRecording() } }, onHome: controller.goHome)
        case .noSpeech:
            FailureScreen(title: "No speech heard", message: controller.message, actionTitle: "Record again", onAction: { Task { await controller.startRecording() } }, onHome: controller.goHome)
        case .transcriptionPending:
            FailureScreen(title: "Saved safely", message: controller.message, actionTitle: "Check again", onAction: { Task { await controller.recoverPendingWork() } }, onHome: controller.goHome)
        default:
            FailureScreen(title: "Could not finish", message: controller.message.isEmpty ? "Your recording is saved." : controller.message,
                          actionTitle: "Try again", onAction: { Task { await controller.recoverPendingWork() } }, onHome: controller.goHome)
        }
    }
}

/// A pushed screen. It observes the controller itself, so it always shows current data (a delivery that completes while
/// the screen is open, a refreshed recent list). Screens built inside the navigation closure would keep their first values.
struct PushedScreen: View {
    @ObservedObject var controller: VoiceReportController
    let route: WatchRootView.Route
    @Binding var path: [WatchRootView.Route]
    @Binding var editor: WatchRootView.Editor?

    var body: some View {
        ScrollView {
            Group {
                switch route {
                case .transcript:
                    TranscriptScreen(text: controller.snapshot?.currentTranscript ?? "", isCorrected: (controller.snapshot?.versions.count ?? 0) > 1,
                                     onEdit: { editor = .transcript }, onNext: { path.append(.triage) })
                case .triage:
                    TriageScreen(provisional: controller.snapshot?.provisional, symptoms: symptoms, onsetMinutes: nil,
                                 uncertainties: controller.snapshot?.processing?.uncertainties.filter { $0.hasPrefix("Contradictory") || $0.hasPrefix("Conflicting") } ?? [],
                                 onDetails: { path.append(.details) })
                    CapsuleButton(title: "View transcript", style: .secondary) { path.append(.transcript) }
                case .details:
                    DetailsScreen(rows: detailRows, onEdit: { editor = .transcript }, onContinue: { path.append(.result) })
                case .result:
                    ResultScreen(state: controller.snapshot?.delivery?.state, held: controller.snapshot?.delivery?.held ?? false, lastError: controller.snapshot?.delivery?.lastError,
                                 onRetry: { Task { if controller.snapshot?.delivery?.held == true { await controller.sendNow() } else { await controller.retryDelivery() } } },
                                 onNew: { path = []; controller.goHome(); Task { await controller.startRecording() } })
                        .task(id: controller.snapshot?.delivery?.state) { await refreshWhileVisible() }
                case .connection:
                    HospitalConnectionView(onRetry: { await controller.sendNowIfPending() })
                case .recent:
                    RecentScreen(reports: controller.recents, onOpen: { report in Task { await controller.open(reportID: report.id); path = [.recent, .transcript] } },
                                 onNew: { path = []; Task { await controller.startRecording() } })
                        .task { await controller.loadRecents() }   // always show what is saved right now
                }
            }.padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var symptoms: [String] {
        (controller.snapshot?.processing?.findings ?? []).filter { $0.kind == "symptom" }.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() }
    }

    /// The extraction surface is limited to these five observations; RAG terms stay separate.
    private var detailRows: [(symbol: String, title: String, value: String?)] {
        let observations = controller.snapshot?.processing?.observations ?? [:]
        let fields: [(String, String, String, [String: String])] = [
            ("lungs.fill", "breathing", "Breathing", ["normal": "Normal", "abnormal": "Difficulty breathing", "absent": "Not breathing"]),
            ("person.fill", "consciousness", "Consciousness", ["alert": "Responsive", "confused": "Confused", "unresponsive": "Unresponsive"]),
            ("drop.fill", "severeBleeding", "Severe Bleeding", ["present": "Present", "absent": "Absent"]),
            ("figure.walk", "walking", "Walking Ability", ["able": "Can walk", "unable": "Cannot walk"]),
            ("heart.fill", "circulation", "Circulation", ["present": "Radial pulse present", "absent": "Radial pulse absent"]),
        ]
        return fields.map { symbol, key, label, values in (symbol, label, values[observations[key] ?? "unknown"] ?? "Unknown") }
    }

    private func refreshWhileVisible() async {
        for _ in 0..<30 {
            await controller.refreshDelivery()
            if controller.snapshot?.delivery?.state == .delivered { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

/// Pure black background. On watchOS it is the navigation container background so it also fills under the title.
struct WatchChrome: ViewModifier {
    /// Back action for hosts that do not get watchOS's own back button and swipe-back. Ignored on watchOS.
    var onBack: (() -> Void)?
    func body(content: Content) -> some View {
        #if os(watchOS)
        content.containerBackground(VanguardPalette.background, for: .navigation)
        #else
        // Outside watchOS nothing draws the title bar, clock or the insets that keep content clear of the rounded
        // display corners, so a host gets an equivalent (used by the Mac development host).
        content
            .safeAreaInset(edge: .top, spacing: 0) { HostTitleBar(onBack: onBack) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 16) }   // keep buttons clear of the rounded corners
            .scrollIndicators(.hidden)
            .padding(.horizontal, 6)
            .background(VanguardPalette.background)
        #endif
    }
}

#if !os(watchOS)
/// Stand-in for the watchOS title bar: app name in the tint color and the clock.
struct HostTitleBar: View {
    var onBack: (() -> Void)?
    var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(VanguardPalette.accent)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Back")
            }
            Text("WristCue").font(.system(size: 14, weight: .semibold)).foregroundStyle(VanguardPalette.accent)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
            }
        }
        .padding(.leading, onBack == nil ? 18 : 10).padding(.trailing, 16).padding(.top, 12).padding(.bottom, 6).background(VanguardPalette.background)
        .accessibilityHidden(true)
    }
}
#endif

// MARK: Editors

struct TranscriptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let onSave: (String) -> Void
    init(original: String, onSave: @escaping (String) -> Void) { _text = State(initialValue: original); self.onSave = onSave }
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Correct transcript").font(.headline)
                TextField("Transcript", text: $text, axis: .vertical).accessibilityLabel("Corrected transcript")
                Text("The original is kept.").font(.caption2).foregroundStyle(VanguardPalette.muted)
                CapsuleButton(title: "Save correction") { onSave(text); dismiss() }
                CapsuleButton(title: "Cancel", style: .secondary) { dismiss() }
            }.padding(.horizontal, 4)
        }
    }
}

/// Optional pairing; capture and local triage never require these settings.
struct HospitalConnectionView: View {
    @State private var hub = UserDefaults.standard.string(forKey: "vanguard-hub") ?? ((try? AppConfiguration.load())?.hubURL.absoluteString ?? "")
    @State private var token = HubCredential.read()
    @State private var enrollmentCode = ""
    @State private var status = ""
    let onRetry: () async -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hospital connection").font(.headline)
            TextField("Hospital LAN URL", text: $hub).autocorrectionDisabled()
            SecureField("Device access token", text: $token)
            Text("Device: " + (UserDefaults.standard.string(forKey: "vanguard-device") ?? "Unknown")).font(.caption2)
            if token.isEmpty {
                TextField("One-time enrollment code", text: $enrollmentCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                CapsuleButton(title: "Enroll Watch", style: .secondary) {
                    Task {
                        guard !enrollmentCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            status = "Enter the one-time code first."
                            return
                        }
                        do {
                            let endpoint = try HubEndpoint(hub)
                            let deviceID = UserDefaults.standard.string(forKey: "vanguard-device") ?? ""
                            let credential = try await HubEnrollment.redeem(code: enrollmentCode, watchID: deviceID, at: endpoint)
                            try HubCredential.save(credential)
                            token = credential; enrollmentCode = ""
                            status = "Watch enrolled; pending reports will retry."
                            await onRetry()
                        } catch { status = "Enrollment failed. Check the code and try again." }
                    }
                }
            } else {
                Text("Watch enrolled; device token is stored securely.").font(.caption)
            }
            CapsuleButton(title: "Save and retry") {
                do {
                    let endpoint = try HubEndpoint(hub)
                    try HubCredential.save(token)
                    UserDefaults.standard.set(endpoint.url.absoluteString, forKey: "vanguard-hub")
                    status = "Connection saved; pending reports will retry."
                    Task { await onRetry() }
                } catch { status = "Invalid LAN address or credential storage unavailable. Reports remain saved." }
            }
            Text(status).font(.caption)
        }
    }
}
