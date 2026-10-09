import XCTest
@testable import VanguardApple

#if os(iOS)
/// Exercises the real AVAudioRecorder path in the iOS simulator (which uses the host Mac's microphone). It proves
/// recording creates a real file and metering returns real, bounded values. It cannot prove speech was captured,
/// and it says nothing about Apple Watch hardware. Needs microphone permission for the test host.
@MainActor
final class MicrophoneRecorderTests: XCTestCase {
    func testRecordsARealFileAndReturnsBoundedMeteredLevels() async throws {
        guard ProcessInfo.processInfo.environment["VANGUARD_LIVE_MIC"] == "1" else { throw XCTSkip("Set VANGUARD_LIVE_MIC=1 in the iOS simulator") }
        let recorder = MicrophoneRecorder()
        guard await recorder.requestPermission() else { throw XCTSkip("Microphone permission was not granted to the test host") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        try recorder.start(to: file)
        XCTAssertTrue(recorder.isRecording)
        var levels: [Float] = []
        for _ in 0..<12 { try await Task.sleep(nanoseconds: 100_000_000); levels.append(recorder.level()) }
        let seconds = try recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertGreaterThan(seconds, 0.8)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 10_000, "about a second of 16 kHz 16-bit mono PCM")
        XCTAssertTrue(levels.allSatisfy { $0 >= 0 && $0 <= 1 && $0.isFinite })
        XCTAssertThrowsError(try recorder.stop(), "stopping twice is an error, not a crash")
        print("MIC ▸ \(String(format: "%.2f", seconds))s, \(size) bytes, peak level \(levels.max() ?? 0)")
    }
}
#endif
