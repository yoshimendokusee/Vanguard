import XCTest
import CryptoKit
@testable import VanguardApple

final class NativeTests: XCTestCase {
    private func fixture() throws -> (URL, ModelArtifact) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("GGUF synthetic test fixture only".utf8)
        let manifest: [String: Any] = ["model": "Qwen3-0.6B", "file": "fixture.gguf", "sizeBytes": data.count,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "revision": String(repeating: "a", count: 40)]
        try data.write(to: directory.appendingPathComponent("fixture.gguf"))
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return (directory, try ModelArtifact.verify(directory: directory))
    }
    func testIntegrityAndMissingWeights() throws {
        let (directory, _) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data("GGUF corrupt test fixture".utf8).write(to: directory.appendingPathComponent("fixture.gguf"))
        XCTAssertThrowsError(try ModelArtifact.verify(directory: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fixture.gguf"))
        XCTAssertThrowsError(try ModelArtifact.verify(directory: directory))
    }
    func testProcessingAndDurableRetryPreserveOriginals() async throws {
        let (directory, artifact) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native.sqlite")
        let capture = NativeCapture(watchID: "SYNTHETIC-WATCH", createdAt: "2026-10-09T00:00:00.000Z", transcript: "Synthetic: cannot walk.")
        let store = try NativeStore(file: file)
        try await store.save(capture); try await store.save(capture)
        let output = try NativeProcessing.validated(generated: "{\"walking\":\"unable\",\"breathing\":\"invented\",\"evidence\":{\"walking\":\"cannot walk\"}}",
            transcript: capture.transcript!, device: .appleWatch, sttEngine: "typed/original", artifact: artifact)
        XCTAssertEqual(output.observations["breathing"], "unknown")
        XCTAssertEqual(output.evidence["walking"]?.source, "model-inferred")
        XCTAssertTrue(output.isValid)
        let pending = try await store.captures(pendingOnly: true); XCTAssertEqual(pending.count, 1)
        try await store.complete(id: capture.id, transcript: capture.transcript!, processingJSON: JSONEncoder().encode(output))
        try await store.complete(id: capture.id, transcript: capture.transcript!, processingJSON: JSONEncoder().encode(output))
        let reopened = try NativeStore(file: file)
        let originals = try await reopened.captures(); XCTAssertEqual(originals[0].transcript, capture.transcript)
        let outbox = try await reopened.outbox(); XCTAssertEqual(outbox.count, 1)
        try await reopened.acknowledge(ids: ["unknown-id"])
        let stillPending = try await reopened.outbox(); XCTAssertEqual(stillPending.count, 1)
        try await reopened.acknowledge(ids: [capture.id])
        let acknowledged = try await reopened.outbox(); XCTAssertTrue(acknowledged.isEmpty)
        do {
            try await reopened.complete(id: capture.id, transcript: "Overwritten", processingJSON: JSONEncoder().encode(output)); XCTFail("Original must remain immutable")
        } catch NativeStoreFailure.transcriptConflict {}
    }
    func testCancellationAndBadRuntimeKeepPendingInput() async throws {
        let (directory, _) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NativeStore(file: directory.appendingPathComponent("retry.sqlite"))
        let workflow = NativeWorkflow(store: store, engine: QwenEngine(directory: directory))
        let capture = NativeCapture(watchID: "SYNTHETIC", createdAt: "2026-10-09T00:00:01Z", transcript: "Synthetic original")
        do { _ = try await workflow.process(capture, device: .iphone); XCTFail("Synthetic GGUF is not a usable model") } catch {}
        let pending = try await store.captures(pendingOnly: true); XCTAssertEqual(pending.count, 1)
        let task = Task { try Task.checkCancellation(); _ = try await workflow.process(capture, device: .iphone) }
        task.cancel(); _ = await task.result
        let retained = try await store.captures(pendingOnly: true); XCTAssertEqual(retained[0].transcript, capture.transcript)
    }
    func testClockRollbackAndEmbeddedNullPreserveExactInput() async throws {
        let (directory, _) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("clock.sqlite")
        let store = try NativeStore(file: file)
        let original = "Synthetic\u{0} original"
        let capture = NativeCapture(watchID: "SYNTHETIC", createdAt: "2099-10-09T00:00:00.000Z", transcript: original)
        try await store.save(capture)
        let reopened = try NativeStore(file: file)
        let next = try await reopened.capture(watchID: "SYNTHETIC", transcript: "Synthetic next")
        XCTAssertGreaterThan(next.createdAt, capture.createdAt)
        let originals = try await reopened.captures()
        XCTAssertEqual(originals[0].transcript, original)
    }

    func testLiveNativeGenerationWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["VANGUARD_LIVE_MODEL_DIR"] else { throw XCTSkip("Set VANGUARD_LIVE_MODEL_DIR for real native execution; fixtures are not inference evidence") }
        if ProcessInfo.processInfo.environment["VANGUARD_REQUIRE_NETWORK_DENIED"] == "1" {
            var request = URLRequest(url: URL(string: "https://1.1.1.1")!); request.timeoutInterval = 2
            do { _ = try await URLSession.shared.data(for: request); XCTFail("External network was not blocked") } catch {}
        }
        let engine = QwenEngine(directory: URL(fileURLWithPath: path))
        let output = try await engine.generate(system: "You are Qwen3-0.6B inside Vanguard.", prompt: "Respond with VANGUARD_QWEN_OK.", maxTokens: 96)
        do {
            _ = try await engine.generate(system: "Synthetic timeout check", prompt: "Reply OK.", timeout: 0.000001)
            XCTFail("Generation must respect its deadline")
        } catch QwenFailure.timeout {}
        XCTAssertGreaterThan(output.generatedTokens, 0)
        XCTAssertFalse(output.text.isEmpty)
        print("Synthetic native generation metrics: \(output.generatedTokens) tokens, \(output.completionSeconds) seconds, \(output.tokensPerSecond) tokens/s, \(output.peakResidentBytes) bytes peak RSS")
        if let hub = ProcessInfo.processInfo.environment["VANGUARD_TEST_HUB_URL"].flatMap(URL.init(string:)) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try NativeStore(file: directory.appendingPathComponent("live.sqlite"))
            let capture = try await store.capture(watchID: "QWEN-SYNTHETIC-NATIVE", transcript: "Synthetic patient is awake and can walk.")
            let workflow = NativeWorkflow(store: store, engine: engine)
            _ = try await workflow.process(capture, device: .iphone)
            let before = try await store.outbox(); XCTAssertEqual(before.count, 1)
            let sent = try await workflow.sync(to: hub); XCTAssertEqual(sent, 1)
            let after = try await store.outbox(); XCTAssertTrue(after.isEmpty)
            let (data, _) = try await URLSession.shared.data(from: hub.appendingPathComponent("api/triage"))
            let reports = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            let report = try XCTUnwrap(reports.first { $0["source_report_id"] as? String == capture.id })
            XCTAssertEqual(report["raw_text"] as? String, capture.transcript)
            XCTAssertEqual(report["effective_triage"] as? String, "Unassessed")
            print("PASS: real native extraction, SQLite outbox, LAN intake and scoped hospital ACK")
        }
    }
}
