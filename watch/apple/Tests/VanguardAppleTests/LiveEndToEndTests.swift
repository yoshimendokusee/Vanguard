import XCTest
@testable import VanguardApple

/// Real Qwen3-0.6B (llama.cpp CPU) + real SQLite + a real running hub. macOS evidence only: it says nothing
/// about Apple Watch or iPhone hardware, and it starts from typed text, not audio.
/// VANGUARD_LIVE_MODEL_DIR=<models/qwen3-0.6b> VANGUARD_TEST_HUB_URL=http://127.0.0.1:3010
final class LiveEndToEndTests: XCTestCase {
    func testTranscriptToHospitalDashboardWithRealModelAndRealHub() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["VANGUARD_LIVE_MODEL_DIR"], let hubText = env["VANGUARD_TEST_HUB_URL"], let hub = URL(string: hubText) else {
            throw XCTSkip("Set VANGUARD_LIVE_MODEL_DIR and VANGUARD_TEST_HUB_URL for the real end-to-end run")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NativeStore(file: directory.appendingPathComponent("e2e.sqlite"))
        let workflow = NativeWorkflow(store: store, engine: QwenEngine(directory: URL(fileURLWithPath: model)))
        let transcript = "Dalawang bata, hindi makalakad, nahihirapan huminga, hindi nagre-respond, may severe bleeding sa leg, pero may radial pulse, sa Barangay Arnaldo, sampung minuto papunta sa ospital."

        // 1. original saved before any inference, 2. real local extraction, 3. deterministic triage
        let capture = try await store.capture(watchID: "APPLE-WATCH-E2E-SYNTHETIC", transcript: transcript)
        let processing = try await workflow.process(capture, device: .appleWatch)
        let triage = try XCTUnwrap(TriageRules.assess(processing.observations))
        print("E2E ▸ observations \(processing.observations.sorted { $0.key < $1.key }) → \(triage.triage.rawValue) (\(triage.reason))")
        XCTAssertEqual(processing.observations, ["breathing": "abnormal", "consciousness": "unresponsive", "severeBleeding": "present", "walking": "unable", "circulation": "present"])
        XCTAssertEqual(triage.triage, .immediate)
        XCTAssertEqual(processing.provenance.extraction.execution, "local")
        var record = try await store.deliveryRecord(captureID: capture.id)
        XCTAssertEqual(record?.state, .queued, "queued automatically, with no human review gate")
        let details = try await store.currentDetails(captureID: capture.id)
        XCTAssertEqual(details, ReportDetails(location: "Barangay Arnaldo", patientCount: 2, ageGroup: "Child", etaMinutes: 10))

        // An unavailable LAN cannot discard offline extraction or mark it delivered.
        do { _ = try await workflow.sync(to: URL(string: "http://127.0.0.1:1")!); XCTFail("Unreachable LAN should fail") } catch {}
        let pending = try await store.deliveryRecord(captureID: capture.id)
        XCTAssertEqual(pending?.state, .retryRequired)
        let retained = try await store.processing(id: capture.id)
        XCTAssertNotNil(retained)

        // 4. transmit and require the hospital's acknowledgment
        let sent = try await workflow.sync(to: hub)
        record = try await store.deliveryRecord(captureID: capture.id)
        print("E2E ▸ delivery state \(record?.state.rawValue ?? "?") \(record?.lastError ?? "")")
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(record?.state, .delivered)

        // 5. read it back from the hospital, exactly as the dashboard does
        let (data, _) = try await URLSession.shared.data(from: hub.appendingPathComponent("api/triage"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["source_report_id"] as? String == capture.id })
        let persisted = try XCTUnwrap(row["processing"] as? [String: Any])
        XCTAssertEqual(persisted["observations"] as? [String: String], processing.observations)
        XCTAssertEqual(row["raw_text"] as? String, transcript)
        XCTAssertEqual(row["location"] as? String, "Barangay Arnaldo"); XCTAssertEqual(row["patient_count"] as? Int, 2)
        XCTAssertEqual(row["age_group"] as? String, "Child"); XCTAssertEqual(row["eta_minutes"] as? Int, 10)
        XCTAssertEqual(row["encounter_id"] as? String, record?.encounterID)
        XCTAssertEqual(row["effective_triage"] as? String, "Unassessed", "the hub never trusts model-inferred findings without verification")
        print("E2E ▸ hospital row id \(row["id"] ?? "?"): \(row["location"] ?? "") · \(row["patient_count"] ?? "") · \(row["age_group"] ?? "") · ETA \(row["eta_minutes"] ?? "") · \(row["effective_triage"] ?? "")")

        // 6. a correction creates a new transcript version and reaches the hospital as a linked revision
        let corrected = transcript + " Walang malay ang isa."
        let version = try await store.appendCorrection(captureID: capture.id, transcript: corrected)
        _ = try await workflow.processCorrection(captureID: capture.id, version: version.version, device: .appleWatch)
        _ = try await workflow.sync(to: hub)
        let (after, _) = try await URLSession.shared.data(from: hub.appendingPathComponent("api/triage"))
        let updated = try XCTUnwrap((JSONSerialization.jsonObject(with: after) as? [[String: Any]])?.first { $0["source_report_id"] as? String == capture.id })
        XCTAssertEqual(updated["current_transcript"] as? String, corrected)
        XCTAssertEqual(updated["raw_text"] as? String, transcript, "the original submission is preserved at the hospital")
        XCTAssertEqual(updated["revision"] as? Int, 1)
        let versions = try await store.transcriptVersions(captureID: capture.id)
        XCTAssertEqual(versions.map(\.version), [0, 1]); XCTAssertNotNil(versions[1].sentAt)
        print("E2E ▸ correction delivered as hub revision \(updated["revision"] ?? "?"); original transcript preserved on both sides")
    }
    func testRealPhoneInferenceFallbackAndBothSendersProduceOneHospitalReport() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["VANGUARD_LIVE_MODEL_DIR"], let base = env["VANGUARD_TEST_HUB_URL"], let hub = URL(string: base) else { throw XCTSkip("Requires isolated hub and local Qwen") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watch = try NativeStore(file: dir.appendingPathComponent("watch.sqlite")), phone = try NativeStore(file: dir.appendingPathComponent("phone.sqlite"))
        let engine = QwenEngine(directory: URL(fileURLWithPath: model))
        let watchFlow = NativeWorkflow(store: watch, engine: engine), phoneFlow = NativeWorkflow(store: phone, engine: engine)
        // Synthetic file retention, not a real STT or paired-radio check.
        let audio = dir.appendingPathComponent("retained.caf")
        let audioBytes = Data("synthetic retained recording".utf8)
        try audioBytes.write(to: audio)
        let capture = try await watch.capture(watchID: "APPLE-WATCH-FALLBACK-SYNTHETIC", transcript: nil, audioPath: audio.path)
        let audioJob = try await watchFlow.fallbackCapture(capture)
        try await phone.saveFallback(audioJob)
        try await watch.saveTranscription(id: capture.id, transcript: "Patient cannot walk, hirap huminga, hindi nagre-respond, may severe bleeding, pero may radial pulse.", engine: "synthetic/saved-Watch-STT")
        let job = try await watchFlow.fallbackCapture(capture)
        let resumed = try await phone.saveFallback(job)
        let processing = try await phoneFlow.process(resumed, device: .iphone)
        XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
        XCTAssertEqual(processing.observations["circulation"], "present")
        XCTAssertEqual(processing.observations.count, 5)
        try await watchFlow.adoptRemote(captureID: capture.id, processingJSON: JSONEncoder().encode(processing))
        let phoneSent = try await phoneFlow.sync(to: hub), watchSent = try await watchFlow.sync(to: hub)
        XCTAssertEqual(phoneSent, 1); XCTAssertEqual(watchSent, 1, "replay is acknowledged without a second report")
        let (data, _) = try await URLSession.shared.data(from: hub.appendingPathComponent("api/triage"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.filter { $0["source_report_id"] as? String == capture.id }.count, 1)
        let row = try XCTUnwrap(rows.first { $0["source_report_id"] as? String == capture.id })
        XCTAssertEqual(row["encounter_id"] as? String, job.encounterID)
        XCTAssertEqual((row["processing"] as? [String: Any])?["observations"] as? [String: String], processing.observations)
    }

}
