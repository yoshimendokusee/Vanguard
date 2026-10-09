import XCTest
import SQLite3
@testable import VanguardApple

final class VoiceStoreTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    static let artifact = ModelArtifact(model: "Qwen3-0.6B", file: "fixture.gguf", sha256: String(repeating: "a", count: 64),
                                        sizeBytes: 100, revision: String(repeating: "b", count: 40))

    /// A valid processing envelope for a synthetic transcript, built through the real validator.
    static func processing(_ transcript: String, generated: String = "{\"walking\":\"able\",\"evidence\":{\"walking\":\"can walk\"}}") throws -> Data {
        try JSONEncoder().encode(NativeProcessing.validated(generated: generated, transcript: transcript, device: .appleWatch,
                                                            sttEngine: "typed/original", artifact: artifact))
    }

    private func store(_ name: String = "native.sqlite") throws -> NativeStore { try NativeStore(file: directory.appendingPathComponent(name)) }

    private func version(_ file: URL) -> Int32 {
        var db: OpaquePointer?; sqlite3_open(file.path, &db); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil); defer { sqlite3_finalize(statement) }
        sqlite3_step(statement); return sqlite3_column_int(statement, 0)
    }
    private func exec(_ file: URL, _ sql: String) {
        var db: OpaquePointer?; sqlite3_open(file.path, &db); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }
    private var migrations: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/VanguardApple/Migrations") }

    // MARK: Migration

    func testUpgradesPopulatedVersionOneDatabaseWithoutLosingData() async throws {
        let file = directory.appendingPathComponent("v1.sqlite")
        exec(file, try String(contentsOf: migrations.appendingPathComponent("0001_native.sql"), encoding: .utf8))
        XCTAssertEqual(version(file), 1)
        let transcript = "Synthetic: Dalawang bata, nalunod."
        exec(file, "INSERT INTO native_captures (id, watch_id, created_at, transcript) VALUES ('11111111-1111-4111-8111-111111111111', 'W-OLD', '2026-10-09T00:00:00.000Z', '\(transcript)')")
        let upgraded = try NativeStore(file: file)
        XCTAssertEqual(version(file), 2)
        let captures = try await upgraded.captures()
        XCTAssertEqual(captures.count, 1); XCTAssertEqual(captures[0].transcript, transcript); XCTAssertEqual(captures[0].watchID, "W-OLD")
        try await upgraded.ensureDelivery(captureID: captures[0].id)
        let record = try await upgraded.deliveryRecord(captureID: captures[0].id)
        XCTAssertEqual(record?.state, .localSaved)
        _ = try NativeStore(file: file)   // reopening is a no-op
        XCTAssertEqual(version(file), 2)
        let reopened = try NativeStore(file: file)
        let again = try await reopened.captures(); XCTAssertEqual(again.count, 1)
    }

    func testFailedMigrationRollsBackAndKeepsTheVersionOneData() throws {
        let file = directory.appendingPathComponent("blocked.sqlite")
        exec(file, try String(contentsOf: migrations.appendingPathComponent("0001_native.sql"), encoding: .utf8))
        exec(file, "INSERT INTO native_captures (id, watch_id, created_at, transcript) VALUES ('22222222-2222-4222-8222-222222222222', 'W', '2026-10-09T00:00:00.000Z', 'kept')")
        exec(file, "CREATE VIEW native_report_revisions AS SELECT 1 AS x")   // makes 0002 fail midway
        XCTAssertThrowsError(try NativeStore(file: file))
        XCTAssertEqual(version(file), 1, "a failed upgrade must not advance the version")
        var db: OpaquePointer?; sqlite3_open(file.path, &db); defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE name = 'native_transcript_versions'", -1, &statement, nil)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE, "the partially applied tables were rolled back"); sqlite3_finalize(statement)
        sqlite3_prepare_v2(db, "SELECT transcript FROM native_captures", -1, &statement, nil)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); sqlite3_finalize(statement)
    }

    // MARK: Transcript versions

    func testCorrectionsNeverOverwriteTheOriginalAndRetriesAreIdempotent() async throws {
        let store = try store()
        let capture = try await store.capture(watchID: "W", transcript: "May lalaki, masakit ang dibdib.")
        let id = UUID().uuidString.lowercased()
        let first = try await store.appendCorrection(captureID: capture.id, transcript: "May lalaki, masakit ang dibdib niya.", requestID: id)
        XCTAssertEqual(first.version, 1)
        let replay = try await store.appendCorrection(captureID: capture.id, transcript: "May lalaki, masakit ang dibdib niya.", requestID: id)
        XCTAssertEqual(replay.version, 1)
        do { _ = try await store.appendCorrection(captureID: capture.id, transcript: "Something else", requestID: id); XCTFail("Reused request ID") } catch NativeStoreFailure.identityConflict {}
        do { _ = try await store.appendCorrection(captureID: capture.id, transcript: "May lalaki, masakit ang dibdib niya."); XCTFail("No-op correction") } catch NativeStoreFailure.transcriptConflict {}
        let versions = try await store.transcriptVersions(captureID: capture.id)
        XCTAssertEqual(versions.map(\.version), [0, 1])
        XCTAssertEqual(versions[0].transcript, "May lalaki, masakit ang dibdib.", "original is untouched")
        let current = try await store.currentTranscript(captureID: capture.id)
        XCTAssertEqual(current, "May lalaki, masakit ang dibdib niya.")
        let stored = try await store.captures()
        XCTAssertEqual(stored[0].transcript, "May lalaki, masakit ang dibdib.")
        do { _ = try await store.appendCorrection(captureID: capture.id, transcript: "   "); XCTFail("Blank") } catch NativeStoreFailure.invalidCapture {}
    }

    func testCorrectionRowsAreImmutableAtTheDatabaseLevel() async throws {
        let file = directory.appendingPathComponent("immutable.sqlite")
        let store = try NativeStore(file: file)
        let capture = try await store.capture(watchID: "W", transcript: "Original.")
        try await store.appendCorrection(captureID: capture.id, transcript: "Corrected.")
        var db: OpaquePointer?; sqlite3_open(file.path, &db); defer { sqlite3_close(db) }
        XCTAssertNotEqual(sqlite3_exec(db, "UPDATE native_transcript_versions SET transcript = 'tampered'", nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(sqlite3_exec(db, "DELETE FROM native_transcript_versions", nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(sqlite3_exec(db, "UPDATE native_captures SET transcript = 'tampered'", nil, nil, nil), SQLITE_OK)
        let versions = try await store.transcriptVersions(captureID: capture.id)
        XCTAssertEqual(versions.last?.transcript, "Corrected.")
    }

    func testRevisedExtractionMustDescribeExactlyThatTranscript() async throws {
        let store = try store()
        let capture = try await store.capture(watchID: "W", transcript: "The patient can walk.")
        let correction = try await store.appendCorrection(captureID: capture.id, transcript: "The patient can walk slowly.")
        do { try await store.completeCorrection(captureID: capture.id, version: 1, processingJSON: Self.processing("The patient can walk.")); XCTFail("Wrong transcript") }
        catch NativeStoreFailure.transcriptConflict {}
        let good = try Self.processing(correction.transcript)
        try await store.completeCorrection(captureID: capture.id, version: 1, processingJSON: good)
        try await store.completeCorrection(captureID: capture.id, version: 1, processingJSON: good)   // idempotent
        let stored = try await store.transcriptVersions(captureID: capture.id).last?.processing
        XCTAssertNotNil(stored)
    }

    // MARK: Delivery

    func testDeliveredRequiresAHospitalReceiptAndCannotBeUndone() async throws {
        let store = try store()
        let capture = try await store.capture(watchID: "W", transcript: "Can walk.")
        try await store.complete(id: capture.id, transcript: "Can walk.", processingJSON: Self.processing("Can walk."))
        try await store.queueForDelivery(captureID: capture.id)
        var record = try await store.deliveryRecord(captureID: capture.id); XCTAssertEqual(record?.state, .queued)
        try await store.setDelivery(captureID: capture.id, .transferring, countAttempt: true)
        try await store.setDelivery(captureID: capture.id, .awaitingReceipt)
        do { try await store.setDelivery(captureID: capture.id, .delivered); XCTFail("No receipt yet") } catch NativeStoreFailure.identityConflict {}
        record = try await store.deliveryRecord(captureID: capture.id)
        XCTAssertEqual(record?.state, .awaitingReceipt); XCTAssertEqual(record?.attempts, 1)
        try await store.acknowledge(ids: [capture.id])
        record = try await store.deliveryRecord(captureID: capture.id); XCTAssertEqual(record?.state, .delivered)
        do { try await store.setDelivery(captureID: capture.id, .retryRequired); XCTFail("Delivered is final") } catch {}
        let deliverable = try await store.deliverable(); XCTAssertTrue(deliverable.isEmpty)
    }

    func testSaveOnlyHoldsAReportOutOfTheOutboxUntilReleased() async throws {
        let store = try store()
        let capture = try await store.capture(watchID: "W", transcript: "Can walk.")
        try await store.complete(id: capture.id, transcript: "Can walk.", processingJSON: Self.processing("Can walk."))
        try await store.setHeld(captureID: capture.id, true)
        try await store.queueForDelivery(captureID: capture.id)
        var held = try await store.deliverable(); XCTAssertTrue(held.isEmpty, "Save only must not be sent")
        var record = try await store.deliveryRecord(captureID: capture.id); XCTAssertEqual(record?.state, .localSaved); XCTAssertEqual(record?.held, true)
        try await store.setHeld(captureID: capture.id, false)
        held = try await store.deliverable(); XCTAssertEqual(held.count, 1)
        record = try await store.deliveryRecord(captureID: capture.id); XCTAssertEqual(record?.state, .queued)
    }

    func testInterruptedTransfersAreRetriedAfterARestartButReceiptsWin() async throws {
        let file = directory.appendingPathComponent("restart.sqlite")
        let store = try NativeStore(file: file)
        let a = try await store.capture(watchID: "W", transcript: "A can walk.")
        let b = try await store.capture(watchID: "W", transcript: "B can walk.")
        for capture in [a, b] { try await store.complete(id: capture.id, transcript: capture.transcript!, processingJSON: Self.processing(capture.transcript!)) }
        try await store.setDelivery(captureID: a.id, .transferring, countAttempt: true)
        try await store.setDelivery(captureID: b.id, .awaitingReceipt, countAttempt: true)
        exec(file, "INSERT INTO native_receipts (capture_id, acknowledged_at) VALUES ('\(b.id)', '2026-10-10T00:00:00.000Z')")   // ack arrived, state write was lost
        let reopened = try NativeStore(file: file)
        try await reopened.recoverInterruptedDelivery()
        let first = try await reopened.deliveryRecord(captureID: a.id), second = try await reopened.deliveryRecord(captureID: b.id)
        XCTAssertEqual(first?.state, .retryRequired)
        XCTAssertEqual(second?.state, .delivered)
    }

    // MARK: Details and summaries

    func testDetailRevisionsAreAppendOnlyAndValidated() async throws {
        let store = try store()
        let capture = try await store.capture(watchID: "W", transcript: "Two children at Barangay Uno.")
        let r1 = try await store.appendDetails(captureID: capture.id, source: "extracted", ReportDetails(location: "Barangay Uno", patientCount: 2, ageGroup: "Child"))
        XCTAssertEqual(r1, 1)
        let same = try await store.appendDetails(captureID: capture.id, source: "extracted", ReportDetails(location: "Barangay Uno", patientCount: 2, ageGroup: "Child"))
        XCTAssertEqual(same, 1, "an unchanged save adds no revision")
        let r2 = try await store.appendDetails(captureID: capture.id, source: "edited", ReportDetails(location: "Barangay Dos", patientCount: 2, ageGroup: "Child", etaMinutes: 10))
        XCTAssertEqual(r2, 2)
        let revisions = try await store.detailRevisions(captureID: capture.id)
        XCTAssertEqual(revisions.map(\.source), ["extracted", "edited"])
        XCTAssertEqual(revisions[0].details.location, "Barangay Uno", "the earlier revision is retained")
        for bad in [ReportDetails(patientCount: 0), ReportDetails(patientCount: 100), ReportDetails(ageGroup: "Teen"), ReportDetails(etaMinutes: 721), ReportDetails(location: "  ")] {
            do { _ = try await store.appendDetails(captureID: capture.id, source: "edited", bad); XCTFail("\(bad)") } catch NativeStoreFailure.invalidDetails {}
        }
    }

    func testRecentReportsListPersistedRowsWithRealTriageAndDelivery() async throws {
        let store = try store()
        let capture = try await store.capture(watchID: "W", transcript: "Responsive, breathing normally, no severe bleeding, can walk.")
        let generated = "{\"breathing\":\"normal\",\"consciousness\":\"alert\",\"severeBleeding\":\"absent\",\"walking\":\"able\",\"evidence\":{\"breathing\":\"breathing normally\",\"consciousness\":\"Awake\",\"severeBleeding\":\"no severe bleeding\",\"walking\":\"can walk\"}}"
        try await store.complete(id: capture.id, transcript: capture.transcript!, processingJSON: Self.processing(capture.transcript!, generated: generated))
        let none = try await store.capture(watchID: "W", transcript: "Unknown things only.")
        try await store.complete(id: none.id, transcript: none.transcript!, processingJSON: Self.processing(none.transcript!, generated: "{}"))
        try await store.queueForDelivery(captureID: none.id)
        let summaries = try await store.reportSummaries()
        XCTAssertEqual(summaries.map(\.id), [none.id, capture.id], "newest first")
        XCTAssertEqual(summaries[1].provisional?.triage, .minor)
        XCTAssertEqual(summaries[0].provisional?.triage, .unassessed, "unknown findings never become Minor")
        XCTAssertEqual(summaries[0].delivery, .queued)
        XCTAssertEqual(summaries[1].delivery, .localSaved)
    }

    func testConcurrentRequestsForOneCaptureShareOneExtraction() async throws {
        let store = try store()
        let workflow = NativeWorkflow(store: store, engine: QwenEngine(directory: directory))
        let counter = Counter()
        await workflow.setOverride(.init(generate: { _ in await counter.bump(); try await Task.sleep(nanoseconds: 80_000_000); return "{\"walking\":\"able\"}" }, artifact: Self.artifact))
        let capture = try await store.capture(watchID: "W", transcript: "Can walk.")
        async let first = workflow.process(capture, device: .appleWatch)
        async let second = workflow.process(capture, device: .appleWatch)
        async let third = workflow.process(capture, device: .appleWatch)
        let results = try await [first, second, third]
        let runs = await counter.value
        XCTAssertEqual(runs, 1, "the model ran once for three simultaneous requests")
        XCTAssertEqual(Set(results.map { $0.observations["walking"] ?? "" }), ["able"])
        let outbox = try await store.outbox(); XCTAssertEqual(outbox.count, 1)
    }
}

private actor Counter { var value = 0; func bump() { value += 1 } }
