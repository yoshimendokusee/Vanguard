import XCTest
@testable import VanguardApple

private final class ReceiptProtocol: URLProtocol {
    static var reply: (URLRequest) throws -> (Int, Data) = { _ in throw URLError(.notConnectedToInternet) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class HubTests: XCTestCase {
    func testEmptyOutboxDoesNotImplyConnectedHub() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NativeStore(file: directory.appendingPathComponent("empty.sqlite"))
        let engine = QwenEngine(directory: directory)
        let workflow = NativeWorkflow(store: store, engine: engine)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReceiptProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        ReceiptProtocol.reply = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await workflow.sync(to: URL(string: "http://hospital.local:3000")!, session: session); XCTFail("Empty queue must still verify connectivity") } catch {}
        let state = await engine.state; XCTAssertEqual(state, .initializing)
        ReceiptProtocol.reply = { request in
            XCTAssertEqual(request.url?.path, "/api/config")
            return (200, Data("{\"contractVersion\":1,\"hospital\":\"Synthetic hospital\"}".utf8))
        }
        let acknowledged = try await workflow.sync(to: URL(string: "http://hospital.local:3000")!, session: session)
        XCTAssertEqual(acknowledged, 0)
    }

    func testEndpointsRejectInvalidOriginsAndDeviceLocalhost() throws {
        for value in ["", "ftp://hub.local", "http://user:secret@hub.local", "http://hub.local/api", "http://hub.local?token=secret", "http://0.0.0.0"] {
            XCTAssertThrowsError(try HubEndpoint(value))
        }
        for value in ["http://localhost:3000", "http://127.0.0.1:3000", "http://[::1]:3000"] {
            XCTAssertThrowsError(try HubEndpoint(value))
        }
        let a = try HubEndpoint("http://hospital-a.local:3000/")
        let b = try HubEndpoint("https://hospital-b.local:8443")
        XCTAssertNotEqual(a.url, b.url)
        let request = try b.request(path: "api/sync-triage", token: "synthetic-token", requestID: "synthetic-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request.url?.absoluteString, "https://hospital-b.local:8443/api/sync-triage")
    }

    func testEnrollmentRedeemsOnlyTheShortLivedCodeShape() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReceiptProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let endpoint = try HubEndpoint("http://hospital.local:3000")
        ReceiptProtocol.reply = { request in
            XCTAssertEqual(request.url?.path, "/api/enrollment/redeem")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data("{\"ok\":true,\"token\":\"synthetic-enrolled-token-12345678901234567890\"}".utf8))
        }
        let token = try await HubEnrollment.redeem(code: "0123456789ABCDEF", watchID: "APPLE-WATCH-SYNTHETIC", at: endpoint, session: session)
        XCTAssertGreaterThanOrEqual(token.utf8.count, 32)
        do {
            _ = try await HubEnrollment.redeem(code: "short", watchID: "APPLE-WATCH-SYNTHETIC", at: endpoint, session: session)
            XCTFail("Short codes must be rejected before networking")
        } catch {}
    }

    func testDisconnectAndInvalidReceiptRetainOutboxUntilReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NativeStore(file: directory.appendingPathComponent("test.sqlite"))
        let capture = try await store.capture(watchID: "SYNTHETIC-WATCH", transcript: "Synthetic original")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../docs/fixtures/ai-v1.json")
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        var processing = body["processing"] as! [String: Any]
        processing["originalTranscript"] = capture.transcript!
        processing["observations"] = ["breathing": "unknown", "consciousness": "unknown", "severeBleeding": "unknown", "walking": "unknown"]
        processing["evidence"] = [String: String]()
        try await store.complete(id: capture.id, transcript: capture.transcript!, processingJSON: JSONSerialization.data(withJSONObject: processing))
        let engine = QwenEngine(directory: directory)
        let workflow = NativeWorkflow(store: store, engine: engine)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReceiptProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let hub = URL(string: "http://hospital.local:3000")!
        for code in [401, 200] {
            ReceiptProtocol.reply = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
                return (code, Data("{\"ok\":true,\"ackLocalIds\":[999],\"inserted\":1,\"duplicates\":0,\"rejected\":[]}".utf8))
            }
            do { _ = try await workflow.sync(to: hub, token: "synthetic", session: session); XCTFail("Invalid receipt must fail") } catch {}
            let retained = try await store.outbox(); XCTAssertEqual(retained.count, 1)
            let local = await engine.state; XCTAssertEqual(local, .initializing)
        }
        ReceiptProtocol.reply = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await workflow.sync(to: hub, session: session); XCTFail("Offline hub must fail") } catch {}
        let pending = try await store.outbox(); XCTAssertEqual(pending.count, 1)
        ReceiptProtocol.reply = { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let report = (envelope["reports"] as! [[String: Any]])[0]
            XCTAssertEqual(report["rawText"] as? String, capture.transcript)
            return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "ackLocalIds": [report["localId"]!], "inserted": 1, "duplicates": 0, "rejected": []]))
        }
        let sent = try await workflow.sync(to: hub, session: session); XCTAssertEqual(sent, 1)
        let after = try await store.outbox(); XCTAssertTrue(after.isEmpty)
    }
}
