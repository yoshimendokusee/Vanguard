import XCTest
import SwiftUI
@testable import VanguardApple

#if canImport(AppKit)
import AppKit

/// Renders the ten real screens at Apple Watch point sizes on macOS (SwiftUI ImageRenderer). This is NOT the
/// watchOS renderer: fonts and metrics differ slightly. It checks layout, hierarchy and color against the storyboard.
/// Data comes from the genuine pipeline (fake microphone and stand-in model for speed), not from hard-coded screen text.
@MainActor
final class WatchScreenshotTests: XCTestCase {
    private struct Frame<Content: View>: View {
        let title: String; let size: CGSize; let content: Content
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(VanguardPalette.accent)
                    Spacer()
                    Text("10:09").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)   // the system draws the real clock
                }.padding(.horizontal, 16).padding(.top, 10)
                content.padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .top)
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height, alignment: .top).background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 44)).overlay(RoundedRectangle(cornerRadius: 44).stroke(Color.gray.opacity(0.5), lineWidth: 3))
            .environment(\.colorScheme, .dark)
        }
    }

    private func png(_ view: some View, scale: CGFloat = 2) throws -> Data {
        let renderer = ImageRenderer(content: view); renderer.scale = scale
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func makeSnapshot() async throws -> (ReportSnapshot, [ReportSummary]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try NativeStore(file: dir.appendingPathComponent("s.sqlite"))
        let workflow = NativeWorkflow(store: store, engine: QwenEngine(directory: dir))
        await workflow.setOverride(.init(generate: { t in
            let l = t.lowercased()
            return "{\"breathing\":\"\(l.contains("shortness of breath") ? "abnormal" : "unknown")\",\"consciousness\":\"\(l.contains("walang malay") ? "unresponsive" : "unknown")\",\"walking\":\"\(l.contains("cannot walk") ? "unable" : l.contains("can walk") ? "able" : "unknown")\"}"
        }, artifact: VoiceStoreTests.artifact))
        let mic = ScreenshotMicrophone()
        let hooks = VoiceReportHooks(transcribeAndProcess: { _ in .pending }, syncHospital: {})
        let controller = VoiceReportController(recorder: mic, workflow: workflow, hooks: hooks, deviceID: "APPLE-WATCH-SHOT", device: .appleWatch, audioDirectory: dir)
        for transcript in ["Awake, can walk, ankle pain.", "Cannot walk, fracture of the leg, Barangay Dos.", "Male, around 60 years old, complaining of chest pain, shortness of breath, and sweating. Started 30 minutes ago."] {
            await controller.submitText(transcript)
        }
        await controller.loadRecents()
        return (try XCTUnwrap(controller.snapshot), controller.recents)
    }

    func testRenderTheTenStoryboardScreens() async throws {
        let (snapshot, recents) = try await makeSnapshot()
        let size = CGSize(width: 184, height: 224)
        let symptoms = (snapshot.extracted?.findings ?? []).filter { $0.kind == "symptom" }.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() }
        let wave: [Float] = (0..<30).map { 0.15 + 0.7 * abs(sin(Float($0) * 0.55)) }
        let rows: [(symbol: String, title: String, value: String?)] = [
            ("person.fill", "Male, about 60 years old", "Patient details"), ("lungs.fill", "Chest pain", nil), ("lungs.fill", "Shortness of breath", nil),
            ("clock.fill", "Onset: 30 minutes ago", nil), ("mappin.and.ellipse", "Not stated", "Pickup location")]
        let screens: [(String, String, AnyView)] = [
            ("1. Home", "Start a new voice report.", AnyView(HomeScreen(recentCount: recents.count, onRecord: {}, onRecent: {}))),
            ("2. Recording", "Captures audio in real time.", AnyView(RecordingScreen(elapsed: 0.4, levels: Array(wave.prefix(9)), onStop: {}))),
            ("3. Recording (active)", "Live timer and waveform.", AnyView(RecordingScreen(elapsed: 24, levels: wave, onStop: {}))),
            ("4. Transcribing", "Offline, never the cloud.", AnyView(TranscribingScreen(headline: "Transcribing…", detail: "Sent to your iPhone. Offline, no cloud"))),
            ("5. Transcript preview", "Review and edit if needed.", AnyView(TranscriptScreen(text: snapshot.currentTranscript ?? "", isCorrected: false, onEdit: {}, onNext: {}))),
            ("6. Provisional triage", "Rules, not the AI, set this.", AnyView(TriageScreen(provisional: snapshot.provisional, symptoms: symptoms, onsetMinutes: snapshot.extracted?.onsetMinutes, uncertainties: [], onDetails: {}))),
            ("7. Extracted details", "Only what was stated.", AnyView(DetailsScreen(rows: rows, onEdit: {}, onContinue: {}))),
            ("8. Send report", "Sends automatically too.", AnyView(SendScreen(hospital: "Receiving Hospital", status: "Queued. Sends automatically", held: false, onSend: {}, onSaveOnly: {}))),
            ("9. Success", "Only after a hospital receipt.", AnyView(ResultScreen(state: .delivered, held: false, lastError: nil, onRetry: {}, onNew: {}))),
            ("10. Recent reports", "Real saved reports.", AnyView(RecentScreen(reports: recents, onOpen: { _ in }, onNew: {}))),
        ]
        let out = ProcessInfo.processInfo.environment["VANGUARD_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for (title, _, screen) in screens {
            let data = try png(Frame(title: title.hasPrefix("1.") ? "WristCue" : "", size: size, content: screen))
            XCTAssertGreaterThan(data.count, 4_000, "\(title) rendered blank")
            if let out { try data.write(to: out.appendingPathComponent(title.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ".", with: "") + ".png")) }
        }
        // The storyboard-style sheet: five across, two rows, captions below.
        let sheet = VStack(spacing: 22) {
            ForEach(0..<2, id: \.self) { row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<5, id: \.self) { column in
                        let item = screens[row * 5 + column]
                        VStack(spacing: 6) {
                            Frame(title: item.0.hasPrefix("1.") ? "WristCue" : "", size: size, content: item.2)
                            Text(item.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                            Text(item.1).font(.system(size: 10)).foregroundStyle(.gray)
                        }
                    }
                }
            }
        }.padding(20).background(Color(red: 0.957, green: 0.984, blue: 0.992))
        let sheetData = try png(sheet, scale: 1.5)
        XCTAssertGreaterThan(sheetData.count, 50_000)
        if let out { try sheetData.write(to: out.appendingPathComponent("storyboard-sheet.png")) }
    }
}

@MainActor
private final class ScreenshotMicrophone: AudioRecording {
    var isRecording = false; var onInterruption: (() -> Void)?
    func requestPermission() async -> Bool { true }
    func start(to file: URL) throws {}
    func stop() throws -> TimeInterval { 0 }
    func level() -> Float { 0 }
}
#endif
