import SwiftUI

/// The Apple Watch app. A thin view over `VoiceReportController`: all behavior (recording, processing,
/// triage, delivery) lives in the controller and the store, so screens can be left and re-entered safely.
public struct WatchRootView: View {
    enum Route: Hashable { case transcript, triage, details, send, result, recent }
    enum Editor: Identifiable { case transcript, details; var id: Int { self == .transcript ? 0 : 1 } }

    @ObservedObject var controller: VoiceReportController
    let hospitalName: String
    @State private var path: [Route] = []
    @State private var editor: Editor?
    private let pinnedStart: Bool

    /// `startRoutes` opens the app already on a pushed screen (by name). Used by the Mac development host to photograph screens.
    public init(controller: VoiceReportController, hospitalName: String = "Receiving Hospital", startRoutes: [String] = []) {
        self.controller = controller; self.hospitalName = hospitalName
        let known: [String: Route] = ["transcript": .transcript, "triage": .triage, "details": .details, "send": .send, "result": .result, "recent": .recent]
        _path = State(initialValue: startRoutes.compactMap { known[$0] }); pinnedStart = !startRoutes.isEmpty
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView { rootContent.padding(.horizontal, 4) }
                .scrollIndicators(.hidden)
                .modifier(WatchChrome())
                .navigationTitle("Vanguard")    // watchOS draws the title in the tint color, teal here, with the system clock
                #if !os(watchOS)
                .toolbar(.hidden)
                #endif
                .navigationDestination(for: Route.self) { route in PushedScreen(controller: controller, route: route, hospitalName: hospitalName, path: $path, editor: $editor)
                        .modifier(WatchChrome(onBack: { if !path.isEmpty { path.removeLast() } })) }
        }
        .tint(VanguardPalette.accent)
        .sheet(item: $editor) { which in
            switch which {
            case .transcript: TranscriptEditor(original: controller.snapshot?.currentTranscript ?? "") { text in Task { await controller.correctTranscript(text) } }
            case .details: DetailsEditor(details: controller.snapshot?.details ?? ReportDetails()) { details in Task { await controller.editDetails(details) } }
            }
        }
        .onChange(of: controller.state) { old, new in
            // A finished report opens on its transcript; earlier screens are replaced, never stacked.
            if new == .ready, !pinnedStart, [.preparingReport, .extracting, .evaluatingTriage].contains(old) { path = [.transcript] }
        }
        .task { await controller.loadRecents(); await controller.recoverPendingWork() }
    }

    // MARK: Root (home / recording / processing / failure)

    @ViewBuilder private var rootContent: some View {
        switch controller.state {
        case .idle, .ready, .queuedForDelivery, .delivering, .delivered:
            HomeScreen(recentCount: controller.recents.count, onRecord: { Task { await controller.startRecording() } }, onRecent: { path.append(.recent) })
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
        "Sent to your iPhone. Offline, no cloud"
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
    let hospitalName: String
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
                    TriageScreen(provisional: controller.snapshot?.provisional, symptoms: symptoms, onsetMinutes: controller.snapshot?.extracted?.onsetMinutes,
                                 uncertainties: controller.snapshot?.processing?.uncertainties.filter { $0.hasPrefix("Contradictory") || $0.hasPrefix("Conflicting") } ?? [],
                                 onDetails: { path.append(.details) })
                case .details:
                    DetailsScreen(rows: detailRows, onEdit: { editor = .details }, onContinue: { path.append(.send) })
                case .send:
                    SendScreen(hospital: hospitalName, status: deliveryStatusLine, held: controller.snapshot?.delivery?.held ?? false,
                               delivered: controller.snapshot?.delivery?.state == .delivered,
                               onSend: { Task { await controller.sendNow() }; path.append(.result) },
                               onSaveOnly: { Task { await controller.saveOnly() }; path.append(.result) })
                case .result:
                    ResultScreen(state: controller.snapshot?.delivery?.state, held: controller.snapshot?.delivery?.held ?? false, lastError: controller.snapshot?.delivery?.lastError,
                                 onRetry: { Task { if controller.snapshot?.delivery?.held == true { await controller.sendNow() } else { await controller.retryDelivery() } } },
                                 onNew: { path = []; controller.goHome(); Task { await controller.startRecording() } })
                        .task(id: controller.snapshot?.delivery?.state) { await refreshWhileVisible() }
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
        (controller.snapshot?.extracted?.findings ?? []).filter { $0.kind == "symptom" }.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() }
    }

    /// Only stated facts. Anything not reported says so.
    private var detailRows: [(symbol: String, title: String, value: String?)] {
        let report = controller.snapshot?.extracted, details = controller.snapshot?.details ?? ReportDetails()
        var who: [String] = []
        if let sex = report?.sex { who.append(sex.capitalized) }
        if let years = report?.ageYears { who.append((report?.ageIsApproximate == true ? "about " : "") + "\(years) years old") }
        else if details.ageGroup != "Unspecified" { who.append(details.ageGroup.lowercased()) }
        var rows: [(String, String, String?)] = [("person.fill", who.isEmpty ? "Patient not described" : who.joined(separator: ", "), "Patient details")]
        let symptoms = self.symptoms
        if symptoms.isEmpty { rows.append(("lungs.fill", "No symptoms reported", nil)) }
        for symptom in symptoms { rows.append(("lungs.fill", symptom, nil)) }
        rows.append(("clock.fill", report?.onsetMinutes.map { "Onset: \($0) minutes ago" } ?? "Onset not reported", nil))
        rows.append(("mappin.and.ellipse", details.location ?? "Not stated", "Pickup location"))
        rows.append(("person.2.fill", details.patientCount.map { "\($0)" } ?? "Unknown", "Number of patients"))
        if let eta = details.etaMinutes { rows.append(("car.fill", "\(eta) minutes", "Estimated arrival")) }
        return rows
    }

    private var deliveryStatusLine: String {
        guard let record = controller.snapshot?.delivery else { return "Saved on this watch" }
        if record.held { return "Saved only. Not sent yet" }
        switch record.state {
        case .delivered: return "Delivered. The hospital confirmed receipt"
        case .queued, .localSaved: return "Queued. Sends automatically"
        case .transferring, .awaitingReceipt: return "Sending…"
        case .retryRequired: return "Will retry automatically"
        case .failedPermanently: return "The hospital did not accept it"
        }
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
            Text("Vanguard").font(.system(size: 14, weight: .semibold)).foregroundStyle(VanguardPalette.accent)
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

struct DetailsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var location: String
    @State private var patients: Int
    @State private var age: String
    @State private var eta: Int
    let onSave: (ReportDetails) -> Void
    init(details: ReportDetails, onSave: @escaping (ReportDetails) -> Void) {
        _location = State(initialValue: details.location ?? ""); _patients = State(initialValue: details.patientCount ?? 0)
        _age = State(initialValue: details.ageGroup); _eta = State(initialValue: details.etaMinutes ?? 0); self.onSave = onSave
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Edit details").font(.headline)
                TextField("Pickup location", text: $location).accessibilityLabel("Pickup location")
                Picker("Patients", selection: $patients) { Text("Unknown").tag(0); ForEach(1...99, id: \.self) { Text("\($0)").tag($0) } }
                Picker("Age group", selection: $age) { ForEach(ReportDetails.ageGroups, id: \.self) { Text($0).tag($0) } }
                Picker("ETA (minutes)", selection: $eta) { Text("Unknown").tag(0); ForEach([1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { Text("\($0)").tag($0) } }
                CapsuleButton(title: "Save") {
                    let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(ReportDetails(location: trimmed.isEmpty ? nil : trimmed, patientCount: patients == 0 ? nil : patients, ageGroup: age, etaMinutes: eta == 0 ? nil : eta)); dismiss()
                }
                CapsuleButton(title: "Cancel", style: .secondary) { dismiss() }
            }.padding(.horizontal, 4)
        }
    }
}
