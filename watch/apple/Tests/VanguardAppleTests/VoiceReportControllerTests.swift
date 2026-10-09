import XCTest
import Combine
@testable import VanguardApple

private actor Seen { var ids: [String] = []; func add(_ id: String) { ids.append(id) } }

@MainActor
private final class FakeMicrophone: AudioRecording {
    var isRecording = false
    var onInterruption: (() -> Void)?
    var permission = true
    var samples: [Float] = [0.2, 0.5, 0.8, 0.4]
    var seconds: TimeInterval = 2.0
    var fileBytes = 4_000
    var startError: Error?
    private var index = 0
    func requestPermission() async -> Bool { permission }
    func start(to file: URL) throws {
        if let startError { throw startError }
        try Data(repeating: 1, count: fileBytes).write(to: file); isRecording = true; index = 0
    }
    func stop() throws -> TimeInterval { isRecording = false; return seconds }
    func level() -> Float { defer { index += 1 }; return samples.isEmpty ? 0 : samples[index % samples.count] }
}

private final class StubHospital: URLProtocol {
    nonisolated(unsafe) static var online = true
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard Self.online else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        let path = request.url?.path ?? ""
        let json: Any
        if path == "/api/config" { json = ["contractVersion": 1, "hospital": "Synthetic hospital"] as [String: Any] }
        else {
            Self.requests += 1
            let report = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["reports"] as? [[String: Any]])?.first
            json = ["ok": true, "ackLocalIds": [report?["localId"] as Any], "inserted": 1, "duplicates": 0, "rejected": []] as [String: Any]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class VoiceReportControllerTests: XCTestCase {
    private var directory: URL!
    private var store: NativeStore!
    private var workflow: NativeWorkflow!
    private var mic: FakeMicrophone!
    private var session: URLSession!
    private var controller: VoiceReportController!
    private var transcribeHook: (@Sendable (NativeCapture) async throws -> TranscriptionOutcome)!
    private var states: [(VoiceReportState, Int)] = []
    private var bag = Set<AnyCancellable>()
    private let hub = URL(string: "http://hospital.local:3000")!

    /// Stands in for the model: reads the transcript like a keyword matcher so the pipeline can be driven offline.
    private nonisolated static func fakeModel(_ transcript: String) -> String {
        let t = transcript.lowercased()
        return "{\"consciousness\":\"\(t.contains("walang malay") ? "unresponsive" : "unknown")\",\"walking\":\"\(t.contains("can walk") ? "able" : "unknown")\"}"
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try NativeStore(file: directory.appendingPathComponent("c.sqlite"))
        workflow = NativeWorkflow(store: store, engine: QwenEngine(directory: directory))
        await workflow.setOverride(.init(generate: { Self.fakeModel($0) }, artifact: VoiceStoreTests.artifact))
        mic = FakeMicrophone()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubHospital.self]
        session = URLSession(configuration: config)
        StubHospital.online = true; StubHospital.requests = 0
        states = []; bag = []
        // What the iPhone does: speech to text (a fixed synthetic transcript), saved as the immutable transcription, then extraction.
        transcribeHook = { [workflow = workflow!, store = store!] capture in
            try await store.saveTranscription(id: capture.id, transcript: "Dalawang bata, walang malay, Barangay Uno, sampung minuto papunta sa ospital.", engine: "SFSpeechRecognizer/on-device")
            _ = try await workflow.process(capture, device: .iphone)
            return .processed
        }
        makeController()
    }
    override func tearDown() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }

    private func makeController() {
        let hooks = VoiceReportHooks(
            transcribeAndProcess: { [unowned self] capture in try await self.transcribeHook(capture) },
            syncHospital: { [workflow = workflow!, hub = hub, session = session!] in _ = try? await workflow.sync(to: hub, session: session) })
        controller = VoiceReportController(recorder: mic, workflow: workflow, hooks: hooks, deviceID: "APPLE-WATCH-TEST", device: .appleWatch,
                                           audioDirectory: directory.appendingPathComponent("Recordings"))
        controller.sampleInterval = 0.005
        controller.$state.sink { [unowned self] in self.states.append(($0, StubHospital.requests)) }.store(in: &bag)
    }

    private func record() async {
        await controller.startRecording()
        try? await Task.sleep(nanoseconds: 60_000_000)
        await controller.stopRecording()
    }

    // MARK: State machine

    func testOnlyLegalTransitionsAreAllowed() {
        XCTAssertTrue(VoiceReportState.canMove(from: .idle, to: .requestingPermission))
        XCTAssertTrue(VoiceReportState.canMove(from: .recording, to: .savingRecording))
        XCTAssertTrue(VoiceReportState.canMove(from: .preparingReport, to: .ready))
        XCTAssertTrue(VoiceReportState.canMove(from: .failed(.noSpeech), to: .requestingPermission), "Try again")
        let illegal: [(VoiceReportState, VoiceReportState)] = [(.recording, .delivered), (.transcribing, .ready), (.idle, .recording), (.delivered, .recording),
                                                               (.savingRecording, .ready), (.extracting, .delivered), (.requestingPermission, .transcribing)]
        for (from, to) in illegal {
            XCTAssertFalse(VoiceReportState.canMove(from: from, to: to), "\(from) → \(to)")
        }
        for state in [VoiceReportState.recording, .transcribing, .ready, .delivered, .failed(.noSpeech)] {
            XCTAssertTrue(VoiceReportState.canMove(from: state, to: .idle), "Home is always reachable")
        }
    }

    func testWaveformLevelsComeFromThePhysicalInputOnly() {
        XCTAssertEqual(AudioLevel.normalize(decibels: -160), 0)
        XCTAssertEqual(AudioLevel.normalize(decibels: -60), 0)
        XCTAssertEqual(AudioLevel.normalize(decibels: 0), 1)
        XCTAssertEqual(AudioLevel.normalize(decibels: 12), 1, "over-range is clamped")
        XCTAssertEqual(AudioLevel.normalize(decibels: -.infinity), 0)
        XCTAssertEqual(AudioLevel.normalize(decibels: .nan), 0)
        XCTAssertLessThan(AudioLevel.normalize(decibels: -40), AudioLevel.normalize(decibels: -20))
    }

    // MARK: Recording

    func testPermissionDeniedExplainsAndRecoversWithoutCreatingAnyRecord() async throws {
        mic.permission = false
        await controller.startRecording()
        XCTAssertEqual(controller.state, .failed(.permissionDenied))
        XCTAssertTrue(controller.message.contains("Settings"))
        let none = try await store.captures(); XCTAssertTrue(none.isEmpty)
        mic.permission = true
        await controller.startRecording()
        XCTAssertEqual(controller.state, .recording)
        await controller.stopRecording()
    }

    func testRecordingShowsRealLevelsAndAnElapsedTime() async throws {
        await controller.startRecording()
        XCTAssertEqual(controller.state, .recording)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(controller.levels.isEmpty)
        XCTAssertTrue(controller.levels.allSatisfy { mic.samples.contains($0) }, "only values the microphone reported are ever shown")
        XCTAssertLessThanOrEqual(controller.levels.count, VoiceReportController.waveformSamples)
        XCTAssertGreaterThan(controller.elapsed, 0.05)
        await controller.stopRecording()
    }

    func testSilenceIsReportedNotTurnedIntoAReportAndTheAudioIsKept() async throws {
        mic.samples = [0, 0, 0]
        await record()
        XCTAssertEqual(controller.state, .failed(.noSpeech))
        let captures = try await store.captures()
        XCTAssertEqual(captures.count, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: captures[0].audioPath!))
        mic.samples = [0.6]
        await record()                       // Try again
        XCTAssertEqual(controller.state, .delivered)
    }

    func testAnInterruptedRecordingKeepsWhatWasCaptured() async throws {
        await controller.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        mic.onInterruption?()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.state, .delivered, "processing continued with the captured audio")
        XCTAssertTrue(controller.message.contains("interrupted"))
        let captures = try await store.captures(); XCTAssertEqual(captures.count, 1)
    }

    func testAnUnavailableMicrophoneLeavesNoHalfReport() async throws {
        struct Busy: Error {}
        mic.startError = Busy()
        await controller.startRecording()
        XCTAssertEqual(controller.state, .failed(.microphoneUnavailable))
        controller.goHome()
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Full pipeline

    func testRecordedSpeechBecomesAnAcknowledgedReportThroughEveryStage() async throws {
        await record()
        let sequence = states.map(\.0)
        for stage in [VoiceReportState.requestingPermission, .recording, .savingRecording, .transcribing, .extracting, .evaluatingTriage, .preparingReport, .ready, .delivered] {
            XCTAssertTrue(sequence.contains(stage), "missing \(stage) in \(sequence)")
        }
        XCTAssertEqual(sequence.last, .delivered)
        // Delivered appears only once the hospital has actually acknowledged a request.
        XCTAssertTrue(states.filter { $0.0 == .delivered }.allSatisfy { $0.1 >= 1 })
        let snapshot = try XCTUnwrap(controller.snapshot)
        XCTAssertEqual(snapshot.versions.first?.transcript, "Dalawang bata, walang malay, Barangay Uno, sampung minuto papunta sa ospital.")
        XCTAssertEqual(snapshot.provisional?.triage, .immediate)
        XCTAssertEqual(snapshot.processing?.observations["consciousness"], "unresponsive")
        XCTAssertEqual(snapshot.details, ReportDetails(), "only the five observations and RAG terms are extracted")
        XCTAssertEqual(snapshot.delivery?.state, .delivered)
        XCTAssertEqual(StubHospital.requests, 1)
    }

    func testWatchLocalTranscriptionFinishesWithoutWaitingForThePairedPhone() async throws {
        transcribeHook = { [workflow = workflow!, store = store!] capture in
            try await store.saveTranscription(id: capture.id,
                transcript: "Awake, can walk. Barangay Uno.", engine: "whisper.cpp/tiny-q5_1")
            _ = try await workflow.process(capture, device: .appleWatch)
            return .processed
        }
        await record()
        XCTAssertEqual(controller.state, .delivered)
        XCTAssertEqual(controller.snapshot?.currentTranscript, "Awake, can walk. Barangay Uno.")
        XCTAssertEqual(controller.snapshot?.processing?.provenance.device, AiDevice.appleWatch.rawValue)
        XCTAssertEqual(StubHospital.requests, 1)
    }

    func testLocalSpeechRecognitionFailureRetainsTheRecording() async throws {
        transcribeHook = { _ in throw TranscriptionFailure.empty }
        await record()
        XCTAssertEqual(controller.state, .failed(.transcriptionUnavailable))
        let pending = try await store.captures(pendingOnly: true)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(pending[0].audioPath)))
        let processing = try await store.processing(id: pending[0].id)
        XCTAssertNil(processing)
    }

    func testSendingAgainAfterDeliveryNeverCreatesADuplicate() async throws {
        await record()
        let before = StubHospital.requests
        await controller.sendNow(); await controller.sendNow()
        XCTAssertEqual(StubHospital.requests, before, "a delivered report is not sent again")
        XCTAssertEqual(controller.snapshot?.delivery?.state, .delivered)
    }

    func testAnUnreachableHospitalQueuesTheReportAndTheNextAttemptDeliversIt() async throws {
        StubHospital.online = false
        await record()
        XCTAssertEqual(controller.state, .queuedForDelivery)
        XCTAssertEqual(controller.snapshot?.delivery?.state, .retryRequired)
        let saved = try await store.captures(); XCTAssertEqual(saved.count, 1, "the report is safe on the device")
        StubHospital.online = true
        await controller.retryDelivery()
        XCTAssertEqual(controller.state, .delivered)
        XCTAssertEqual(StubHospital.requests, 1)
    }

    func testSaveOnlyKeepsTheReportOffTheNetworkUntilSent() async throws {
        StubHospital.online = false
        await record()
        await controller.saveOnly()
        StubHospital.online = true
        await controller.recoverPendingWork()
        XCTAssertEqual(StubHospital.requests, 0, "a saved-only report is never transmitted")
        XCTAssertEqual(controller.recents.first?.held, true)
        await controller.sendNow()
        XCTAssertEqual(controller.state, .delivered)
        XCTAssertEqual(StubHospital.requests, 1)
    }

    func testAnUnavailablePhoneKeepsTheAudioAndRecoversLater() async throws {
        transcribeHook = { _ in .pending }
        await record()
        XCTAssertEqual(controller.state, .failed(.transcriptionPending))
        let pending = try await store.captures(pendingOnly: true)
        XCTAssertEqual(pending.count, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: pending[0].audioPath!))
        transcribeHook = { [workflow = workflow!, store = store!] capture in
            try await store.saveTranscription(id: capture.id, transcript: "Awake, can walk. Barangay Dos.", engine: "SFSpeechRecognizer/on-device")
            _ = try await workflow.process(capture, device: .iphone); return .processed
        }
        await controller.recoverPendingWork()
        let stillPending = try await store.captures(pendingOnly: true); XCTAssertTrue(stillPending.isEmpty)
        XCTAssertEqual(controller.recents.first?.delivery, .delivered)
    }

    func testRecoveryNeverTouchesTheCaptureBeingRecordedRightNow() async throws {
        let seen = Seen()
        transcribeHook = { capture in await seen.add(capture.id); return .pending }
        await controller.startRecording()
        XCTAssertEqual(controller.state, .recording)
        await controller.recoverPendingWork()         // e.g. the app's launch task racing the first recording
        let during = await seen.ids
        XCTAssertTrue(during.isEmpty, "a half-recorded file must not be transcribed")
        await controller.stopRecording()
        let after = await seen.ids
        XCTAssertEqual(after.count, 1, "it is processed once, when the recording is finished")
    }

    func testAProcessingFailureKeepsTheTranscriptAndAudio() async throws {
        struct Boom: Error {}
        transcribeHook = { _ in throw Boom() }
        await record()
        XCTAssertEqual(controller.state, .failed(.processingFailed))
        let captures = try await store.captures(); XCTAssertEqual(captures.count, 1); XCTAssertNotNil(captures[0].audioPath)
    }

    // MARK: Corrections and edits

    func testACorrectionIsANewVersionAndTriageIsReassessed() async throws {
        await controller.submitText("Can walk. Barangay Tres.")
        XCTAssertEqual(controller.snapshot?.provisional?.triage, .unassessed, "unknown findings are not Minor")
        let original = try XCTUnwrap(controller.snapshot?.currentTranscript)
        await controller.correctTranscript("Can walk. Barangay Tres. Walang malay ang isa.")
        let snapshot = try XCTUnwrap(controller.snapshot)
        XCTAssertEqual(snapshot.versions.map(\.version), [0, 1])
        XCTAssertEqual(snapshot.versions[0].transcript, original, "the original is never overwritten")
        XCTAssertEqual(snapshot.provisional?.triage, .immediate, "the corrected evidence triggered reassessment")
        XCTAssertEqual(snapshot.processing?.originalTranscript, "Can walk. Barangay Tres. Walang malay ang isa.")
        XCTAssertNil(snapshot.details.location, "pickup location is no longer extracted")
    }

    func testAContradictoryCorrectionIsNotResolvedByTheAI() async throws {
        await controller.submitText("Can walk. Barangay Tres.")
        await controller.correctTranscript("Awake and can walk, Barangay Tres. Walang malay ang isa.")
        XCTAssertNotEqual(controller.snapshot?.provisional?.triage, .immediate, "awake and unconscious in one report stays unknown")
        XCTAssertEqual(controller.snapshot?.processing?.observations["consciousness"], "unknown")
        XCTAssertTrue(controller.snapshot?.processing?.uncertainties.contains { $0.contains("Contradictory") } == true, "the conflict stays visible")
    }

    func testEditingDetailsKeepsEveryRevisionAndRejectsInvalidValues() async throws {
        await controller.submitText("Awake, can walk.")
        await controller.editDetails(ReportDetails(location: "Plaza", patientCount: 3, ageGroup: "Adult", etaMinutes: 5))
        let id = try XCTUnwrap(controller.snapshot?.captureID)
        let revisions = try await store.detailRevisions(captureID: id)
        XCTAssertEqual(revisions.map(\.source), ["extracted", "edited"])
        await controller.editDetails(ReportDetails(patientCount: 500))
        XCTAssertTrue(controller.message.contains("not valid"))
        let after = try await store.detailRevisions(captureID: id); XCTAssertEqual(after.count, 2)
    }

    // MARK: Recent reports

    func testRecentReportsAreReadFromPersistedReportsAndReopenable() async throws {
        await record()
        controller.goHome()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.recents.count, 1)
        let first = try XCTUnwrap(controller.recents.first)
        XCTAssertEqual(first.provisional?.triage, .immediate); XCTAssertEqual(first.delivery, .delivered)
        // A fresh controller (an app restart) sees the same persisted rows.
        makeController()
        await controller.loadRecents()
        XCTAssertEqual(controller.recents.map(\.id), [first.id])
        await controller.open(reportID: first.id)
        XCTAssertEqual(controller.state, .delivered)
        XCTAssertEqual(controller.snapshot?.currentTranscript, "Dalawang bata, walang malay, Barangay Uno, sampung minuto papunta sa ospital.")
    }
}
