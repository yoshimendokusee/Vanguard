import XCTest
@testable import VanguardApple

private actor FixtureRepository: FallbackRepository {
    var captures = [PendingCapture(captureID: "synthetic-1", watchID: "W-TEST",
        createdAt: "2026-10-09T00:00:00.000Z", audioFile: URL(fileURLWithPath: "/synthetic.wav"))]
    var refuseCommit = true
    func pendingCaptures() -> [PendingCapture] { captures }
    func commitProcessed(capture: PendingCapture, transcript: String, processingJSON: Data) throws {
        if refuseCommit { throw CocoaError(.fileWriteUnknown) }
        captures.removeAll { $0.captureID == capture.captureID }
    }
    func allowCommit() { refuseCommit = false }
}

// State-machine fixture only: this is not speech or model execution evidence.
private struct FixtureProcessor: OfflineCaptureProcessor {
    func process(_ capture: PendingCapture) async throws -> (transcript: String, processingJSON: Data) {
        ("Synthetic test transcript", Data("{}".utf8))
    }
}

private struct CancelledProcessor: OfflineCaptureProcessor {
    func process(_ capture: PendingCapture) async throws -> (transcript: String, processingJSON: Data) {
        throw CancellationError()
    }
}

final class FallbackProcessorTests: XCTestCase {
    func testCancellationRetainsTheCapture() async throws {
        let repository = FixtureRepository()
        let fallback = FallbackProcessor(repository: repository, processor: CancelledProcessor())
        do {
            _ = try await fallback.recover()
            XCTFail("Cancellation must stop recovery")
        } catch is CancellationError {
            let pending = await repository.pendingCaptures()
            XCTAssertEqual(pending.count, 1)
        }
    }

    func testFailedCommitRetainsPendingCaptureAndRecoveryCommitsOnce() async throws {
        let repository = FixtureRepository()
        let fallback = FallbackProcessor(repository: repository, processor: FixtureProcessor())
        let first = try await fallback.recover()
        XCTAssertFalse(first[0].committed)
        let pending = await repository.pendingCaptures()
        XCTAssertEqual(pending.count, 1)
        await repository.allowCommit()
        let recovered = try await fallback.recover()
        XCTAssertTrue(recovered[0].committed)
        let replay = try await fallback.recover()
        XCTAssertTrue(replay.isEmpty)
    }
}
