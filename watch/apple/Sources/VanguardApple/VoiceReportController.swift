import Foundation
import Combine

/// Why a voice report stopped. Every case keeps the captured audio or transcript on the device.
public enum VoiceReportFailure: Equatable, Sendable {
    case permissionDenied, microphoneUnavailable, noSpeech, interrupted, storageUnavailable
    /// The audio is saved; the paired iPhone has not returned a transcript yet.
    case transcriptionPending
    case transcriptionUnavailable, processingFailed
}

/// Recording and processing lifecycle. Delivery is tracked separately (`DeliveryState`, persisted), so
/// processing and network sync never depend on which screen is visible.
public enum VoiceReportState: Equatable, Sendable {
    case idle, requestingPermission, recording, savingRecording, transcribing, extracting
    case evaluatingTriage, preparingReport, ready, queuedForDelivery, delivering, delivered
    case failed(VoiceReportFailure)

    /// The only legal transitions. Anything else is a programming error and is refused.
    public static func canMove(from: VoiceReportState, to: VoiceReportState) -> Bool {
        if to == .idle { return true }                              // Home is always reachable; data stays saved
        switch (from, to) {
        case (.idle, .requestingPermission), (.idle, .extracting), (.idle, .ready): return true
        case (.requestingPermission, .recording), (.requestingPermission, .failed): return true
        case (.recording, .savingRecording), (.recording, .failed): return true
        case (.savingRecording, .transcribing), (.savingRecording, .failed): return true
        case (.transcribing, .extracting), (.transcribing, .failed): return true
        case (.extracting, .evaluatingTriage), (.extracting, .failed): return true
        case (.evaluatingTriage, .preparingReport), (.evaluatingTriage, .failed): return true
        case (.preparingReport, .ready), (.preparingReport, .failed): return true
        case (.ready, .queuedForDelivery), (.ready, .extracting), (.ready, .delivering), (.ready, .delivered): return true
        case (.queuedForDelivery, .delivering), (.queuedForDelivery, .delivered), (.queuedForDelivery, .extracting): return true
        case (.delivering, .delivered), (.delivering, .queuedForDelivery), (.delivering, .extracting): return true
        case (.delivered, .extracting), (.delivered, .queuedForDelivery), (.delivered, .delivering): return true
        case (.failed, .requestingPermission), (.failed, .extracting), (.failed, .transcribing): return true
        default: return false
        }
    }
}

public enum TranscriptionOutcome: Sendable { case processed, pending }

/// What the app needs from the platform. The Watch relays audio to the paired iPhone and waits; the iPhone
/// transcribes on-device itself. Hospital sync talks to the existing LAN hub.
public struct VoiceReportHooks: Sendable {
    public var transcribeAndProcess: @Sendable (NativeCapture) async throws -> TranscriptionOutcome
    public var syncHospital: @Sendable () async -> Void
    public init(transcribeAndProcess: @escaping @Sendable (NativeCapture) async throws -> TranscriptionOutcome, syncHospital: @escaping @Sendable () async -> Void) {
        self.transcribeAndProcess = transcribeAndProcess; self.syncHospital = syncHospital
    }
}

/// Everything a screen shows about one report, read from persisted rows only.
public struct ReportSnapshot: Equatable, Sendable {
    public var captureID: String
    public var createdAt: String
    public var versions: [TranscriptVersion]
    public var processing: NativeProcessing?
    public var provisional: ProvisionalTriage?
    public var extracted: ExtractedReport?
    public var details: ReportDetails
    public var delivery: DeliveryRecord?
    public var currentTranscript: String? { versions.last?.transcript }
    public static func == (a: Self, b: Self) -> Bool { a.captureID == b.captureID && a.versions == b.versions && a.details == b.details && a.delivery == b.delivery && a.provisional == b.provisional }
}

@MainActor
public final class VoiceReportController: ObservableObject {
    @Published public private(set) var state: VoiceReportState = .idle
    @Published public private(set) var elapsed: TimeInterval = 0
    /// Most recent microphone levels, oldest first. Real input only.
    @Published public private(set) var levels: [Float] = []
    @Published public private(set) var snapshot: ReportSnapshot?
    @Published public private(set) var recents: [ReportSummary] = []
    @Published public private(set) var message = ""

    public static let waveformSamples = 40
    public var minimumRecordingSeconds: TimeInterval = 0.8
    public var silenceFloor: Float = 0.04
    public var sampleInterval: TimeInterval = 0.05

    private let recorder: AudioRecording
    private let workflow: NativeWorkflow
    private let hooks: VoiceReportHooks
    private let deviceID: String
    private let device: AiDevice
    private let audioDirectory: URL
    private var capture: NativeCapture?
    private var peakLevel: Float = 0
    private var sampler: Task<Void, Never>?
    private var started = Date()

    public init(recorder: AudioRecording, workflow: NativeWorkflow, hooks: VoiceReportHooks, deviceID: String, device: AiDevice, audioDirectory: URL) {
        self.recorder = recorder; self.workflow = workflow; self.hooks = hooks
        self.deviceID = deviceID; self.device = device; self.audioDirectory = audioDirectory
        recorder.onInterruption = { [weak self] in Task { @MainActor in await self?.interrupted() } }
    }

    /// True while this controller is recording or processing its own capture.
    private var isWorking: Bool {
        switch state {
        case .requestingPermission, .recording, .savingRecording, .transcribing, .extracting, .evaluatingTriage, .preparingReport: return true
        default: return false
        }
    }

    private func move(_ next: VoiceReportState) {
        guard VoiceReportState.canMove(from: state, to: next) else { return }
        state = next
    }

    /// A new report may start from Home, after a failure, or once the previous report finished processing.
    /// Processing, delivery and everything saved carry on independently of what the screen shows.
    static func canStartNew(_ state: VoiceReportState) -> Bool {
        switch state {
        case .idle, .failed, .ready, .queuedForDelivery, .delivering, .delivered: return true
        default: return false
        }
    }

    // MARK: Recording

    /// Home → permission → recording. Needs neither network nor hospital connectivity.
    public func startRecording() async {
        guard Self.canStartNew(state) else { return }
        state = .idle
        move(.requestingPermission); message = ""
        guard await recorder.requestPermission() else { move(.failed(.permissionDenied)); message = "Microphone access is off. Turn it on in Settings, then try again."; return }
        do {
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let file = audioDirectory.appendingPathComponent(UUID().uuidString.lowercased() + ".caf")
            // The session exists on disk before the first sample, so a crash still leaves a recoverable capture.
            capture = try await workflow.store.capture(watchID: deviceID, transcript: nil, audioPath: file.path)
            try recorder.start(to: file)
        } catch let failure as NativeStoreFailure {
            _ = failure; move(.failed(.storageUnavailable)); message = "Could not create a local recording. Free some storage and try again."; return
        } catch { move(.failed(.microphoneUnavailable)); message = "The microphone is unavailable right now."; return }
        levels = []; elapsed = 0; peakLevel = 0; started = Date()
        move(.recording)
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = self.recorder.level()
                self.peakLevel = max(self.peakLevel, level)
                self.levels = Array((self.levels + [level]).suffix(Self.waveformSamples))
                self.elapsed = Date().timeIntervalSince(self.started)
                try? await Task.sleep(nanoseconds: UInt64(self.sampleInterval * 1_000_000_000))
            }
        }
    }

    public func stopRecording() async {
        guard state == .recording, let capture else { return }
        sampler?.cancel(); sampler = nil
        move(.savingRecording)
        let seconds: TimeInterval
        do { seconds = try recorder.stop() } catch { move(.failed(.microphoneUnavailable)); message = "Recording stopped unexpectedly. Your audio so far is kept."; return }
        await finishRecording(capture, seconds: seconds, interrupted: false)
    }

    private func interrupted() async {
        guard state == .recording, let capture else { return }
        sampler?.cancel(); sampler = nil
        move(.savingRecording)
        let seconds = (try? recorder.stop()) ?? Date().timeIntervalSince(started)
        await finishRecording(capture, seconds: seconds, interrupted: true)
    }

    private func finishRecording(_ capture: NativeCapture, seconds: TimeInterval, interrupted: Bool) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: capture.audioPath ?? "")[.size] as? Int) ?? 0
        guard size > 1_000 else { move(.failed(.noSpeech)); message = "Nothing was recorded. Try again."; return }
        // The audio file is kept either way. Silence is reported, never silently turned into a report.
        guard seconds >= minimumRecordingSeconds, peakLevel >= silenceFloor else {
            move(.failed(.noSpeech)); message = "No speech was heard. The recording is saved. Try again."; return
        }
        if interrupted { message = "Recording was interrupted. What was captured is saved." }
        await transcribe(capture)
    }

    // MARK: Processing

    private func transcribe(_ capture: NativeCapture) async {
        move(.transcribing)
        do {
            switch try await hooks.transcribeAndProcess(capture) {
            case .pending:
                move(.failed(.transcriptionPending))
                message = "Saved safely. Watch transcription did not finish; the paired iPhone can retry when reachable."
            case .processed:
                await prepareReport(capture.id)
            }
        } catch is CancellationError { move(.failed(.transcriptionPending)); message = "Saved safely. Processing will resume." }
        catch TranscriptionFailure.permissionRequired { move(.failed(.transcriptionUnavailable)); message = "Speech recognition is not allowed on this device. Audio is saved." }
        catch TranscriptionFailure.onDeviceUnavailable { move(.failed(.transcriptionUnavailable)); message = "Offline speech recognition is unavailable on this device. Audio is saved." }
        catch TranscriptionFailure.empty { move(.failed(.transcriptionUnavailable)); message = "No transcript was produced. Audio is saved; try again or use the paired iPhone." }
        catch TranscriptionFailure.timeout { move(.failed(.transcriptionUnavailable)); message = "Offline transcription took too long. Audio is saved; try again or use the paired iPhone." }
        catch { move(.failed(.processingFailed)); message = "Processing failed. Audio and transcript are saved; try again." }
    }

    /// Typed or dictated text uses the same pipeline (no audio). The original is stored before any inference.
    public func submitText(_ text: String) async {
        guard Self.canStartNew(state) else { return }
        state = .idle
        move(.extracting)    // busy before the capture exists, so recovery never treats it as pending work
        do {
            let capture = try await workflow.store.capture(watchID: deviceID, transcript: text)
            self.capture = capture
            _ = try await workflow.process(capture, device: device)
            await prepareReport(capture.id)
        } catch { move(.failed(.processingFailed)); message = "Processing failed. The text is saved; try again." }
    }

    private func prepareReport(_ id: String) async {
        move(.extracting)
        do {
            move(.evaluatingTriage)
            snapshot = try await loadSnapshot(id)
            move(.preparingReport)
            move(.ready)
            await refreshDelivery()
            await hooks.syncHospital()
            await refreshDelivery()
            await loadRecents()
        } catch { move(.failed(.processingFailed)); message = "The report could not be prepared. It is saved; try again." }
    }

    /// Re-reads the saved report. The triage shown is the shared deterministic rules on validated observations.
    public func loadSnapshot(_ id: String) async throws -> ReportSnapshot {
        let store = workflow.store
        guard let capture = try await store.captures().first(where: { $0.id == id }) else { throw NativeStoreFailure.invalidCapture }
        let versions = try await store.transcriptVersions(captureID: id)
        // The newest version with processing wins; an unprocessed correction falls back to the previous extraction.
        let processingData = versions.reversed().compactMap(\.processing).first
        let processing = processingData.flatMap { try? JSONDecoder().decode(NativeProcessing.self, from: $0) }
        let extracted = versions.last.map { ReportExtraction.extract(transcript: $0.transcript, pack: workflow.pack) }
        return ReportSnapshot(captureID: id, createdAt: capture.createdAt, versions: versions, processing: processing,
                              provisional: processing.flatMap { TriageRules.assess($0.observations) }, extracted: extracted,
                              details: try await store.currentDetails(captureID: id) ?? ReportDetails(),
                              delivery: try await store.deliveryRecord(captureID: id))
    }

    // MARK: Review and edits (never gate delivery)

    /// Adds a corrected transcript as a new version, re-extracts it, reassesses, and queues the revision.
    public func correctTranscript(_ text: String) async {
        guard let id = snapshot?.captureID else { return }
        do {
            let version = try await workflow.store.appendCorrection(captureID: id, transcript: text)
            move(.extracting)
            _ = try await workflow.processCorrection(captureID: id, version: version.version, device: device)
            snapshot = try await loadSnapshot(id)
            move(.evaluatingTriage); move(.preparingReport); move(.ready)
            await hooks.syncHospital(); await refreshDelivery()
        } catch NativeStoreFailure.transcriptConflict { message = "Nothing was changed."; move(.ready) }
        catch { message = "The correction is saved; reassessment will retry."; move(.failed(.processingFailed)) }
    }

    /// Saves edited report details as a new revision. Only the first (pre-delivery) details reach the hospital's
    /// source fields; later edits are kept locally because the hub has no revision path for them.
    public func editDetails(_ details: ReportDetails) async {
        guard let id = snapshot?.captureID else { return }
        do { _ = try await workflow.store.appendDetails(captureID: id, source: "edited", details); snapshot = try await loadSnapshot(id) }
        catch { message = "Those details are not valid. Nothing was changed." }
    }

    // MARK: Delivery

    public func refreshDelivery() async {
        guard let id = snapshot?.captureID, let record = try? await workflow.store.deliveryRecord(captureID: id) else { return }
        snapshot?.delivery = record
        switch record.state {
        case .delivered: move(.delivered)
        case .transferring, .awaitingReceipt: move(.delivering)
        case .queued, .retryRequired: move(.queuedForDelivery)
        case .localSaved, .failedPermanently: break
        }
    }

    /// Send: release any hold and attempt delivery now.
    public func sendNow() async {
        guard let id = snapshot?.captureID else { return }
        try? await workflow.store.setHeld(captureID: id, false)
        try? await workflow.store.queueForDelivery(captureID: id)
        await hooks.syncHospital(); await refreshDelivery(); await loadRecents()
    }

    /// Save only: keep the report on this device and out of the delivery queue until released.
    public func saveOnly() async {
        guard let id = snapshot?.captureID else { return }
        try? await workflow.store.setHeld(captureID: id, true)
        await refreshDelivery(); await loadRecents()
    }

    /// Retry after a failure, including a permanently rejected report the person decides to try again.
    public func retryDelivery() async {
        guard let id = snapshot?.captureID else { return }
        try? await workflow.store.setDelivery(captureID: id, .queued)
        await hooks.syncHospital(); await refreshDelivery(); await loadRecents()
    }

    // MARK: Recent reports and recovery

    /// The paired iPhone returned a transcript for a capture whose wait had already given up (or that was
    /// recorded earlier). The result is already stored; this finishes the report and starts delivery.
    public func resultArrived(_ id: String) async {
        if capture?.id == id, state == .failed(.transcriptionPending) { await prepareReport(id); return }
        if capture?.id == id, state == .transcribing { return }   // the waiting call will pick it up
        await hooks.syncHospital()
        await loadRecents()
    }

    public func loadRecents() async { recents = (try? await workflow.store.reportSummaries(limit: 20)) ?? recents }

    public func open(reportID: String) async {
        guard let snapshot = try? await loadSnapshot(reportID) else { return }
        self.snapshot = snapshot
        state = .idle; move(.ready)
        await refreshDelivery()
    }

    public func goHome() { sampler?.cancel(); sampler = nil; state = .idle; message = "" ; Task { await loadRecents() } }

    /// At launch: any audio capture without a result is offered for transcription again, and interrupted sends are retried.
    public func recoverPendingWork() async {
        try? await workflow.store.recoverInterruptedDelivery()
        for pending in (try? await workflow.store.captures(pendingOnly: true)) ?? [] where pending.audioPath != nil || pending.transcript != nil {
            // The capture being recorded or processed right now is not "pending": its audio may still be growing.
            if isWorking, pending.id == capture?.id { continue }
            _ = try? await hooks.transcribeAndProcess(pending)
        }
        await hooks.syncHospital()
        await loadRecents()
    }
}
