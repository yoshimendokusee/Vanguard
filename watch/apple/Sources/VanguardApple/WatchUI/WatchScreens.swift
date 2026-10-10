import SwiftUI

// The ten screens of the WristCue Apple Watch storyboard. Every value shown comes from persisted report data
// or the live recorder. Nothing here is a sample. The system draws the clock, so screens do not draw their own.

enum ReportTime {
    /// "10:02 AM" from a stored ISO timestamp, in the wearer's locale.
    static func display(_ iso: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds)); return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: 1 · Home

public struct HomeScreen: View {
    let recentCount: Int
    var onRecord: () -> Void
    var onRecent: () -> Void
    public init(recentCount: Int, onRecord: @escaping () -> Void, onRecent: @escaping () -> Void) { self.recentCount = recentCount; self.onRecord = onRecord; self.onRecent = onRecent }
    public var body: some View {
        VStack(spacing: 4) {
            Button(action: onRecord) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [VanguardPalette.micTealTop, VanguardPalette.micTealBottom], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "mic.fill").font(.system(size: 40, weight: .regular)).foregroundStyle(.white)
                }
                .frame(width: 76, height: 76)
            }
            .buttonStyle(.plain).accessibilityLabel("Record a voice report").accessibilityHint("Starts recording from the microphone")
            Text("Tap to record").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
            Text("Voice → Transcript → Triage").font(.system(.caption2)).foregroundStyle(VanguardPalette.muted).lineLimit(1).minimumScaleFactor(0.75)
            Button(action: onRecent) {
                HStack {
                    Image(systemName: "doc.text").font(.footnote)
                    Text("Recent (\(recentCount))").font(.system(.footnote, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(.white).background(Capsule().fill(VanguardPalette.surface))
            }
            .buttonStyle(.plain).accessibilityLabel("Recent reports, \(recentCount)")
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 6)
    }
}

// MARK: 2 and 3 · Recording

/// Bars driven only by real microphone levels. With no input the bars rest at their minimum height.
public struct WaveformView: View {
    let levels: [Float]
    var color = VanguardPalette.accent
    var bars = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(levels: [Float], color: Color = VanguardPalette.accent, bars: Int = 28) { self.levels = levels; self.color = color; self.bars = bars }
    public var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { index in
                    let offset = bars - levels.count
                    let level = index >= offset ? CGFloat(levels[index - offset]) : 0
                    Capsule().fill(color).frame(width: 3, height: max(3, level * proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .linear(duration: 0.05), value: levels)
        }
        .accessibilityHidden(true)
    }
}

public struct RecordingScreen: View {
    let elapsed: TimeInterval
    let levels: [Float]
    var onStop: () -> Void
    public init(elapsed: TimeInterval, levels: [Float], onStop: @escaping () -> Void) { self.elapsed = elapsed; self.levels = levels; self.onStop = onStop }
    /// The first moments show "Listening…" (storyboard screen 2); once audio is running it shows the live timer (screen 3).
    private var listening: Bool { elapsed < 1.0 }
    public var body: some View {
        VStack(spacing: 8) {
            if listening {
                Text("Listening…").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
                ZStack {
                    Circle().stroke(VanguardPalette.accent.opacity(0.55), lineWidth: 3)
                    WaveformView(levels: levels, bars: 9).padding(.horizontal, 20).frame(height: 40)
                }.frame(width: 96, height: 96)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(VanguardPalette.highPriority).frame(width: 8, height: 8)
                    Text(ReportTime.clock(elapsed)).font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                }
                .padding(.horizontal, 12).padding(.vertical, 4).background(Capsule().fill(VanguardPalette.surface))
                .accessibilityElement(children: .combine).accessibilityLabel("Recording, \(Int(elapsed)) seconds")
                WaveformView(levels: levels, bars: 30).frame(height: 44)
            }
            Button(action: onStop) {
                ZStack {
                    Circle().fill(VanguardPalette.recordRed)
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 16, height: 16)
                }.frame(width: 54, height: 54)
            }
            .buttonStyle(.plain).accessibilityLabel("Stop recording")
            if !listening { Text("Tap to stop").font(.caption).foregroundStyle(.white) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: 4 · Transcribing

public struct TranscribingScreen: View {
    let headline: String
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false
    public init(headline: String, detail: String) { self.headline = headline; self.detail = detail }
    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(VanguardPalette.accent.opacity(0.25), lineWidth: 4)
                Circle().trim(from: 0, to: 0.72).stroke(VanguardPalette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
            }.frame(width: 56, height: 56).onAppear { if !reduceMotion { spin = true } }
            Text(headline).font(.system(.headline, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(detail).font(.caption2).foregroundStyle(VanguardPalette.muted).multilineTextAlignment(.center)
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.caption2)
                Text("Qwen 3 · Local AI").font(.caption2)
            }.foregroundStyle(VanguardPalette.accent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
}

// MARK: 5 · Transcript preview

public struct TranscriptScreen: View {
    let text: String
    let isCorrected: Bool
    var onEdit: () -> Void
    var onNext: () -> Void
    public init(text: String, isCorrected: Bool, onEdit: @escaping () -> Void, onNext: @escaping () -> Void) { self.text = text; self.isCorrected = isCorrected; self.onEdit = onEdit; self.onNext = onNext }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
            Text(text).font(.system(.footnote)).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(VanguardPalette.card))
                .accessibilityLabel("Transcript: \(text)")
            if isCorrected { Label("Corrected. The original is kept.", systemImage: "pencil").font(.caption2).foregroundStyle(VanguardPalette.muted) }
            HStack(spacing: 6) {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil").font(.system(.footnote, weight: .medium)).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.white).background(Capsule().fill(VanguardPalette.surface))
                }.buttonStyle(.plain).accessibilityLabel("Edit transcript")
                Button(action: onNext) {
                    Label("Next", systemImage: "arrow.right").font(.system(.footnote, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.white).background(Capsule().fill(VanguardPalette.teal))
                }.buttonStyle(.plain).accessibilityLabel("Next")
            }
        }
    }
}

// MARK: 6 · Provisional triage

public struct TriageScreen: View {
    let provisional: ProvisionalTriage?
    let symptoms: [String]
    let onsetMinutes: Int?
    let uncertainties: [String]
    var onDetails: () -> Void
    public init(provisional: ProvisionalTriage?, symptoms: [String], onsetMinutes: Int?, uncertainties: [String], onDetails: @escaping () -> Void) {
        self.provisional = provisional; self.symptoms = symptoms; self.onsetMinutes = onsetMinutes; self.uncertainties = uncertainties; self.onDetails = onDetails
    }
    public var body: some View {
        let look = TriagePresentation.of(provisional?.triage)
        VStack(alignment: .leading, spacing: 6) {
            Text("Triage (Provisional)").font(.system(.caption, weight: .medium)).foregroundStyle(.white)
                .accessibilityLabel("Triage, provisional. A qualified person must verify.")
            HStack(spacing: 8) {
                Image(systemName: look.symbol).font(.title3).foregroundStyle(look.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(look.title).font(.system(.callout, weight: .bold)).foregroundStyle(look.color)
                    Text(provisional?.reason ?? "No report assessed yet").font(.caption2).foregroundStyle(.white).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 14).fill(look.fill))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Provisional triage: \(look.title). \(provisional?.reason ?? "")")
            fact("text.book.closed.fill", symptoms.isEmpty ? "RAG terms: none found" : "RAG: " + symptoms.joined(separator: ", "))
            if !uncertainties.isEmpty { Text(uncertainties.joined(separator: " · ")).font(.caption2).foregroundStyle(VanguardPalette.amber) }
            CapsuleButton(title: "View details", minHeight: 40, action: onDetails)
        }
    }
    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(VanguardPalette.muted).frame(width: 16)
            Text(text).font(.system(.caption, weight: .medium)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

// MARK: 7 · Key details

public struct DetailsScreen: View {
    struct Row: Identifiable { let id = UUID(); let symbol: String; let title: String; let value: String? }
    let rows: [(symbol: String, title: String, value: String?)]
    var onEdit: () -> Void
    var onContinue: () -> Void
    public init(rows: [(symbol: String, title: String, value: String?)], onEdit: @escaping () -> Void, onContinue: @escaping () -> Void) { self.rows = rows; self.onEdit = onEdit; self.onContinue = onContinue }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Key details").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 4)
                Button("Edit transcript", action: onEdit).font(.caption).buttonStyle(.plain).padding(.horizontal, 10).frame(minHeight: 28)
                    .background(Capsule().fill(VanguardPalette.surface)).foregroundStyle(.white).accessibilityLabel("Edit transcript")
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Image(systemName: row.symbol).font(.footnote).foregroundStyle(VanguardPalette.muted).frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.title).font(.system(.caption, weight: .medium)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                        if let value = row.value { Text(value).font(.system(size: 10)).foregroundStyle(VanguardPalette.muted) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(VanguardPalette.row))
                .accessibilityElement(children: .combine)
            }
            CapsuleButton(title: "Continue", symbol: "arrow.right", minHeight: 40, action: onContinue)
        }
    }
}

// MARK: 8 · Send

public struct SendScreen: View {
    let hospital: String
    let status: String
    let held: Bool
    let delivered: Bool
    var onSend: () -> Void
    var onSaveOnly: () -> Void
    public init(hospital: String, status: String, held: Bool, delivered: Bool = false, onSend: @escaping () -> Void, onSaveOnly: @escaping () -> Void) {
        self.hospital = hospital; self.status = status; self.held = held; self.delivered = delivered; self.onSend = onSend; self.onSaveOnly = onSaveOnly
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Send report").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
            HStack(spacing: 8) {
                Image(systemName: "building.2.fill").foregroundStyle(.white).frame(width: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(hospital).font(.system(.footnote, weight: .semibold)).foregroundStyle(.white)
                    Text("Emergency Department").font(.system(size: 10)).foregroundStyle(VanguardPalette.muted).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 14).fill(VanguardPalette.card)).accessibilityElement(children: .combine)
            if delivered {
                Label(status, systemImage: "checkmark.circle.fill").font(.system(.footnote, weight: .medium)).foregroundStyle(VanguardPalette.green)
                Text("This report was already acknowledged, so it will not be sent again.").font(.caption2).foregroundStyle(VanguardPalette.muted)
            } else {
                Text(status).font(.caption2).foregroundStyle(VanguardPalette.muted)
                CapsuleButton(title: held ? "Send now" : "Send", symbol: "plus", minHeight: 40, action: onSend)
                CapsuleButton(title: "Save only", symbol: "doc.text", style: .secondary, minHeight: 40, action: onSaveOnly)
            }
        }
    }
}

// MARK: 9 · Delivery result

public struct ResultScreen: View {
    enum Kind { case delivered, sending, pending, failed, rejected, savedOnly }
    let state: DeliveryState?
    let held: Bool
    let lastError: String?
    var onRetry: () -> Void
    var onNew: () -> Void
    public init(state: DeliveryState?, held: Bool, lastError: String?, onRetry: @escaping () -> Void, onNew: @escaping () -> Void) { self.state = state; self.held = held; self.lastError = lastError; self.onRetry = onRetry; self.onNew = onNew }
    private var kind: Kind {
        if state == .delivered { return .delivered }
        if held || state == .localSaved { return .savedOnly }
        if state == .transferring || state == .awaitingReceipt { return .sending }
        if state == .failedPermanently { return .rejected }
        if state == .retryRequired { return .failed }
        return .pending
    }
    public var body: some View {
        VStack(spacing: 8) {
            switch kind {
            case .delivered:
                ZStack { Circle().fill(VanguardPalette.successFill); Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(VanguardPalette.green) }.frame(width: 64, height: 64)
                Text("Report sent").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
                Text("Backend acknowledged receipt; clinical review pending").font(.caption).foregroundStyle(VanguardPalette.muted).multilineTextAlignment(.center)
                CapsuleButton(title: "New report", symbol: "plus", style: .secondary, action: onNew)
            case .savedOnly:
                icon("tray.full.fill", VanguardPalette.accent)
                Text("Saved on this watch").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
                Text("Not sent. You chose Save only.").font(.caption).foregroundStyle(VanguardPalette.muted).multilineTextAlignment(.center)
                CapsuleButton(title: "Send now", action: onRetry)
                CapsuleButton(title: "New report", symbol: "plus", style: .secondary, action: onNew)
            case .sending:
                ProgressView().tint(VanguardPalette.accent)
                Text("Sending…").font(.headline)
                Text("Saved locally; awaiting backend acknowledgment").font(.caption).foregroundStyle(VanguardPalette.muted)
            case .pending:
                icon("clock.fill", VanguardPalette.amber)
                Text("Pending Sync").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
                Text("Waiting for hospital connection").font(.caption).foregroundStyle(VanguardPalette.muted).multilineTextAlignment(.center)
                CapsuleButton(title: "Retry", symbol: "arrow.clockwise", action: onRetry)
                CapsuleButton(title: "New report", symbol: "plus", style: .secondary, action: onNew)
            case .failed:
                icon("exclamationmark.triangle.fill", VanguardPalette.amber)
                Text("Not delivered yet").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
                Text("Your report is saved safely").font(.caption).foregroundStyle(VanguardPalette.muted).multilineTextAlignment(.center)
                CapsuleButton(title: "Retry", symbol: "arrow.clockwise", action: onRetry)
                CapsuleButton(title: "New report", symbol: "plus", style: .secondary, action: onNew)
            case .rejected:
                icon("xmark.octagon.fill", VanguardPalette.highPriority)
                Text("Failed to send").font(.system(.headline, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                Text(lastError ?? "Your report is saved safely").font(.caption2).foregroundStyle(VanguardPalette.muted).multilineTextAlignment(.center)
                CapsuleButton(title: "Retry", symbol: "arrow.clockwise", action: onRetry)
            }
        }
        .frame(maxWidth: .infinity).accessibilityElement(children: .contain)
    }
    private func icon(_ name: String, _ color: Color) -> some View {
        ZStack { Circle().fill(color.opacity(0.18)); Image(systemName: name).font(.system(size: 26)).foregroundStyle(color) }.frame(width: 60, height: 60)
    }
}

// MARK: 10 · Recent reports

public struct RecentScreen: View {
    let reports: [ReportSummary]
    var onOpen: (ReportSummary) -> Void
    var onNew: () -> Void
    public init(reports: [ReportSummary], onOpen: @escaping (ReportSummary) -> Void, onNew: @escaping () -> Void) { self.reports = reports; self.onOpen = onOpen; self.onNew = onNew }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent reports").font(.system(.headline, weight: .semibold)).foregroundStyle(.white)
            if reports.isEmpty { Text("No reports yet. They stay on this watch.").font(.caption).foregroundStyle(VanguardPalette.muted) }
            ForEach(reports) { report in
                let look = TriagePresentation.of(report.provisional?.triage)
                Button { onOpen(report) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(look.color).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ReportTime.display(report.createdAt)).font(.system(.caption, weight: .semibold)).foregroundStyle(.white)
                            Text(look.title).font(.system(size: 10)).foregroundStyle(VanguardPalette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: Self.deliverySymbol(report)).font(.caption2).foregroundStyle(report.delivery == .delivered ? VanguardPalette.green : VanguardPalette.muted)
                            .accessibilityHidden(true)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(VanguardPalette.muted)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(VanguardPalette.card)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(ReportTime.display(report.createdAt)), \(look.title), \(Self.delivery(report))")
            }
            CapsuleButton(title: "New report", symbol: "plus", style: .secondary, action: onNew)
        }
    }
    static func deliverySymbol(_ report: ReportSummary) -> String {
        if report.held { return "tray.full" }
        switch report.delivery {
        case .delivered: return "checkmark.circle.fill"
        case .localSaved: return "internaldrive"
        case .queued, .retryRequired: return "clock"
        case .transferring, .awaitingReceipt: return "arrow.up.circle"
        case .failedPermanently: return "exclamationmark.circle"
        }
    }
    static func delivery(_ report: ReportSummary) -> String {
        if report.held { return "Saved only" }
        switch report.delivery {
        case .delivered: return "Delivered"
        case .localSaved: return "Saved"
        case .queued: return "Queued"
        case .transferring, .awaitingReceipt: return "Sending"
        case .retryRequired: return "Will retry"
        case .failedPermanently: return "Not accepted"
        }
    }
}

// MARK: Failures

public struct FailureScreen: View {
    let title: String
    let message: String
    let actionTitle: String
    var onAction: () -> Void
    var onHome: () -> Void
    public init(title: String, message: String, actionTitle: String, onAction: @escaping () -> Void, onHome: @escaping () -> Void) { self.title = title; self.message = message; self.actionTitle = actionTitle; self.onAction = onAction; self.onHome = onHome }
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(VanguardPalette.amber)
            Text(title).font(.system(.headline, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(message).font(.caption).foregroundStyle(VanguardPalette.muted).multilineTextAlignment(.center)
            CapsuleButton(title: actionTitle, action: onAction)
            CapsuleButton(title: "Home", style: .secondary, action: onHome)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .contain)
    }
}
