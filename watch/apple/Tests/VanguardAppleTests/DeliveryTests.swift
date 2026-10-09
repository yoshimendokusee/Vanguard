import XCTest
@testable import VanguardApple

private final class StubHub: URLProtocol {
    nonisolated(unsafe) static var handler: (URLRequest, [String: Any]?) throws -> (Int, Any) = { _, _ in throw URLError(.notConnectedToInternet) }
    nonisolated(unsafe) static var log: [(method: String, path: String, body: [String: Any]?)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        Self.log.append((request.httpMethod ?? "GET", request.url?.path ?? "", body))
        do {
            let (code, json) = try Self.handler(request, body)
            let payload = try JSONSerialization.data(withJSONObject: json)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class DeliveryTests: XCTestCase {
    private var directory: URL!
    private var store: NativeStore!
    private var workflow: NativeWorkflow!
    private var session: URLSession!
    private let hub = URL(string: "http://hospital.local:3000")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try NativeStore(file: directory.appendingPathComponent("delivery.sqlite"))
        workflow = NativeWorkflow(store: store, engine: QwenEngine(directory: directory))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubHub.self]
        session = URLSession(configuration: config)
        StubHub.log = []
        StubHub.handler = { _, _ in throw URLError(.notConnectedToInternet) }
    }
    override func tearDown() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }

    /// A finished, queued report with the given details. The model is not involved: processing is built through the real validator.
    private func queuedReport(_ transcript: String, details: ReportDetails? = nil) async throws -> NativeCapture {
        let capture = try await store.capture(watchID: "APPLE-WATCH-SYNTHETIC", transcript: transcript)
        try await store.complete(id: capture.id, transcript: transcript, processingJSON: VoiceStoreTests.processing(transcript))
        if let details { try await store.appendDetails(captureID: capture.id, source: "extracted", details) }
        try await store.queueForDelivery(captureID: capture.id)
        return capture
    }
    /// A hub that acknowledges any report and answers the connectivity check an empty queue makes.
    private func acknowledging(_ request: URLRequest, _ body: [String: Any]?) -> (Int, Any) {
        request.url?.path == "/api/config" ? (200, ["contractVersion": 1, "hospital": "Synthetic hospital"] as [String: Any]) : ack(body)
    }
    private func ack(_ body: [String: Any]?, inserted: Int = 1, duplicates: Int = 0) -> (Int, Any) {
        let report = (body?["reports"] as? [[String: Any]])?.first
        return (200, ["ok": true, "ackLocalIds": [report?["localId"] as Any], "inserted": inserted, "duplicates": duplicates, "rejected": []] as [String: Any])
    }

    func testDeliveredOnlyAfterAValidReceiptAndStructuredFieldsAreSent() async throws {
        let capture = try await queuedReport("Dalawang bata, Barangay Uno, sampung minuto.", details: ReportDetails(location: "Barangay Uno", patientCount: 2, ageGroup: "Child", etaMinutes: 10))
        StubHub.handler = { _, body in self.ack(body) }
        let sent = try await workflow.sync(to: hub, session: session)
        XCTAssertEqual(sent, 1)
        let record = try await store.deliveryRecord(captureID: capture.id)
        XCTAssertEqual(record?.state, .delivered); XCTAssertEqual(record?.attempts, 1)
        let report = try XCTUnwrap((StubHub.log.first { $0.path == "/api/sync-triage" }?.body?["reports"] as? [[String: Any]])?.first)
        XCTAssertEqual(report["reportId"] as? String, capture.id)
        XCTAssertEqual(report["encounterId"] as? String, record?.encounterID)
        XCTAssertEqual(report["location"] as? String, "Barangay Uno"); XCTAssertEqual(report["patientCount"] as? Int, 2)
        XCTAssertEqual(report["ageGroup"] as? String, "Child"); XCTAssertEqual(report["etaMinutes"] as? Int, 10)
        XCTAssertEqual(report["triage"] as? String, "Unassessed", "the source category stays provisional/Unassessed")
        XCTAssertEqual(report["rawText"] as? String, "Dalawang bata, Barangay Uno, sampung minuto.")
    }

    func testUnknownDetailsAreSentAsUnknownNeverAsZero() async throws {
        _ = try await queuedReport("Awake, can walk.")
        StubHub.handler = { _, body in self.ack(body) }
        _ = try await workflow.sync(to: hub, session: session)
        let report = try XCTUnwrap((StubHub.log.first { $0.path == "/api/sync-triage" }?.body?["reports"] as? [[String: Any]])?.first)
        XCTAssertTrue(report["patientCount"] is NSNull, "an unknown count is null, not 0 or 1")
        XCTAssertTrue(report["etaMinutes"] is NSNull)
        XCTAssertEqual(report["location"] as? String, "Unspecified"); XCTAssertEqual(report["ageGroup"] as? String, "Unspecified")
    }

    func testAnInvalidReceiptIsNeverDeliveredAndTheRetryIsTheSameReport() async throws {
        let capture = try await queuedReport("Awake, can walk.")
        StubHub.handler = { _, _ in (200, ["ok": true, "ackLocalIds": [999], "inserted": 1, "duplicates": 0, "rejected": []] as [String: Any]) }
        do { _ = try await workflow.sync(to: hub, session: session); XCTFail("Wrong receipt") } catch {}
        var record = try await store.deliveryRecord(captureID: capture.id)
        XCTAssertEqual(record?.state, .retryRequired); XCTAssertEqual(record?.attempts, 1)
        let outbox = try await store.outbox(); XCTAssertEqual(outbox.count, 1, "nothing was acknowledged")
        StubHub.handler = { _, body in self.ack(body, inserted: 0, duplicates: 1) }   // the hub already had it: an idempotent replay
        let sent = try await workflow.sync(to: hub, session: session)
        XCTAssertEqual(sent, 1)
        record = try await store.deliveryRecord(captureID: capture.id)
        XCTAssertEqual(record?.state, .delivered); XCTAssertEqual(record?.attempts, 2)
        let ids = StubHub.log.compactMap { ($0.body?["reports"] as? [[String: Any]])?.first?["reportId"] as? String }
        XCTAssertEqual(Set(ids), [capture.id], "every retry carries the same persistent report ID, so the hub cannot duplicate it")
    }

    func testOfflineKeepsTheReportAndReconnectingDeliversIt() async throws {
        let capture = try await queuedReport("Awake, can walk.")
        do { _ = try await workflow.sync(to: hub, session: session); XCTFail("Offline") } catch {}
        var record = try await store.deliveryRecord(captureID: capture.id); XCTAssertEqual(record?.state, .retryRequired)
        let transcripts = try await store.captures(); XCTAssertEqual(transcripts[0].transcript, "Awake, can walk.", "the original is intact")
        StubHub.handler = { _, body in self.ack(body) }
        _ = try await workflow.sync(to: hub, session: session)
        record = try await store.deliveryRecord(captureID: capture.id); XCTAssertEqual(record?.state, .delivered)
    }

    func testAHospitalRejectionIsPermanentButOtherReportsStillSend() async throws {
        let bad = try await queuedReport("First report. Can walk.")
        let good = try await queuedReport("Second report. Can walk.")
        StubHub.handler = { _, body in
            let report = (body?["reports"] as? [[String: Any]])?.first
            if report?["reportId"] as? String == bad.id { return (200, ["ok": true, "ackLocalIds": [], "inserted": 0, "duplicates": 0, "rejected": [["reason": "invalid ageGroup"]]] as [String: Any]) }
            return self.ack(body)
        }
        let sent = try await workflow.sync(to: hub, session: session)
        XCTAssertEqual(sent, 1)
        let failed = try await store.deliveryRecord(captureID: bad.id), delivered = try await store.deliveryRecord(captureID: good.id)
        XCTAssertEqual(failed?.state, .failedPermanently); XCTAssertTrue(failed?.lastError?.contains("invalid ageGroup") == true)
        XCTAssertEqual(delivered?.state, .delivered)
        StubHub.log = []
        StubHub.handler = { request, body in self.acknowledging(request, body) }
        _ = try await workflow.sync(to: hub, session: session)
        XCTAssertFalse(StubHub.log.contains { ($0.body?["reports"] as? [[String: Any]])?.first?["reportId"] as? String == bad.id }, "a rejected report is not hammered")
        let summaries = try await store.reportSummaries()
        XCTAssertEqual(summaries.first { $0.id == bad.id }?.delivery, .failedPermanently, "the data is preserved and visible")
    }

    func testSaveOnlyIsNeverTransmittedUntilTheNurseReleasesIt() async throws {
        let capture = try await queuedReport("Awake, can walk.")
        try await store.setHeld(captureID: capture.id, true)
        StubHub.handler = { request, body in self.acknowledging(request, body) }
        let sent = try await workflow.sync(to: hub, session: session)   // empty queue still verifies the hub
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(StubHub.log.contains { $0.path == "/api/sync-triage" })
        try await store.setHeld(captureID: capture.id, false)
        _ = try await workflow.sync(to: hub, session: session)
        let record = try await store.deliveryRecord(captureID: capture.id); XCTAssertEqual(record?.state, .delivered)
    }

    func testCorrectionAfterDeliveryIsSentOnceAsALinkedRevision() async throws {
        let capture = try await queuedReport("Masakit ang dibdib.")
        StubHub.handler = { _, body in self.ack(body) }
        _ = try await workflow.sync(to: hub, session: session)
        let correction = try await store.appendCorrection(captureID: capture.id, transcript: "Masakit ang dibdib at nahihirapan huminga.")
        var revisionCalls = 0
        StubHub.handler = { request, body in
            switch (request.httpMethod ?? "GET", request.url!.path) {
            case ("GET", "/api/config"): return (200, ["contractVersion": 1, "hospital": "Synthetic hospital"] as [String: Any])
            case ("GET", "/api/triage"): return (200, [["id": 7, "source_report_id": capture.id, "revision": 0]] as [[String: Any]])
            case ("POST", "/api/triage/7/revisions"):
                revisionCalls += 1
                if revisionCalls == 1 { return (409, ["ok": false, "error": "Stale base revision"] as [String: Any]) }
                XCTAssertEqual(body?["kind"] as? String, "correction"); XCTAssertEqual(body?["baseRevision"] as? Int, 0)
                XCTAssertEqual(body?["requestId"] as? String, correction.requestID); XCTAssertEqual(body?["transcript"] as? String, correction.transcript)
                XCTAssertTrue((body?["actor"] as? String)?.hasPrefix("apple-watch:") == true)
                return (200, ["id": 7, "revision": 1, "current_transcript": correction.transcript] as [String: Any])
            default: return (404, ["ok": false] as [String: Any])
            }
        }
        _ = try await workflow.sync(to: hub, session: session)
        var pending = try await store.correctionsToSend(); XCTAssertEqual(pending.count, 1, "a 409 keeps the correction queued")
        _ = try await workflow.sync(to: hub, session: session)
        pending = try await store.correctionsToSend(); XCTAssertTrue(pending.isEmpty)
        _ = try await workflow.sync(to: hub, session: session)
        XCTAssertEqual(revisionCalls, 2, "an acknowledged correction is not sent again")
        let versions = try await store.transcriptVersions(captureID: capture.id)
        XCTAssertEqual(versions[0].transcript, "Masakit ang dibdib.", "the original transcript is unchanged")
        XCTAssertNotNil(versions[1].sentAt)
    }

    func testARestartMidTransferRetriesRatherThanLosingOrDuplicating() async throws {
        let capture = try await queuedReport("Awake, can walk.")
        try await store.setDelivery(captureID: capture.id, .transferring, countAttempt: true)   // the app died mid-request
        let reopened = try NativeStore(file: directory.appendingPathComponent("delivery.sqlite"))
        let resumed = NativeWorkflow(store: reopened, engine: QwenEngine(directory: directory))
        StubHub.handler = { _, body in self.ack(body) }
        let sent = try await resumed.sync(to: hub, session: session)
        XCTAssertEqual(sent, 1)
        let record = try await reopened.deliveryRecord(captureID: capture.id)
        XCTAssertEqual(record?.state, .delivered)
    }
}
