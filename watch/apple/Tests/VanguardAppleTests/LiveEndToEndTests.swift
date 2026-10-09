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
        let transcript = "Dalawang bata, nalunod at walang malay, nahihirapan huminga, sa Barangay Arnaldo, sampung minuto papunta sa ospital."

        // 1. original saved before any inference, 2. real local extraction, 3. deterministic triage
        let capture = try await store.capture(watchID: "APPLE-WATCH-E2E-SYNTHETIC", transcript: transcript)
        let processing = try await workflow.process(capture, device: .appleWatch)
        let triage = try XCTUnwrap(TriageRules.assess(processing.observations))
        print("E2E ▸ observations \(processing.observations.sorted { $0.key < $1.key }) → \(triage.triage.rawValue) (\(triage.reason))")
        XCTAssertEqual(processing.observations["consciousness"], "unresponsive")
        XCTAssertEqual(triage.triage, .immediate)
        XCTAssertEqual(processing.provenance.extraction.execution, "local")
        var record = try await store.deliveryRecord(captureID: capture.id)
        XCTAssertEqual(record?.state, .queued, "queued automatically, with no human review gate")
        let details = try await store.currentDetails(captureID: capture.id)
        XCTAssertEqual(details, ReportDetails(location: "Barangay Arnaldo", patientCount: 2, ageGroup: "Child", etaMinutes: 10))

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
}
