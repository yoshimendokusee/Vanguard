import XCTest
@testable import VanguardApple

final class AiContractTests: XCTestCase {
    private let extractJSON = """
    {"ok":true,"processing":{"version":1,"originalTranscript":"Synthetic patient is awake, breathing normally, no severe bleeding, can walk.","observations":{"breathing":"normal","consciousness":"alert","severeBleeding":"absent","walking":"able"},"uncertainties":["Extracted observations require qualified verification"],"provenance":{"device":"iphone","sttEngine":"SFSpeechRecognizer/on-device","sttRuntime":"iOS"}},"evidence":{"breathing":"breathing normally","consciousness":"awake","severeBleeding":"no severe bleeding","walking":"can walk"},"warnings":[],"provisional":{"triage":"Minor","reason":"Walking, alert, normal breathing, no severe bleeding reported","requiresVerification":true,"advisoryOnly":true},"model":"qwen3:0.6b","promptVersion":"vanguard-extract-v1"}
    """

    func testRequestValidationKeepsBadInputOffTheNetwork() {
        XCTAssertThrowsError(try AiRequest(transcript: "   ", device: .iphone))
        XCTAssertThrowsError(try AiRequest(transcript: String(repeating: "a", count: 4001), device: .iphone))
        XCTAssertNoThrow(try AiRequest(transcript: "Synthetic", device: .appleWatch))
        XCTAssertEqual(AiRequest.extractPath, "/api/ai/extract")
    }

    func testExtractionDecodesHubShape() throws {
        let result = try JSONDecoder().decode(AiExtractionResult.self, from: Data(extractJSON.utf8))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.processing.observations.breathing, "normal")
        XCTAssertEqual(result.evidence(for: "walking"), "can walk")
        XCTAssertEqual(result.provisional.triage, "Minor")
        XCTAssertTrue(result.provisional.requiresVerification)
        XCTAssertNil(result.draft)
    }

    func testUnknownDeviceFallsBackInsteadOfFailing() throws {
        let data = Data("{\"transcript\":\"Synthetic\",\"device\":\"toaster\"}".utf8)
        let request = try JSONDecoder().decode(AiRequest.self, from: data)
        XCTAssertEqual(request.device, "hospital-browser")
    }

    func testStatusAndErrorDecode() throws {
        let status = try JSONDecoder().decode(
            AiStatus.self,
            from: Data("{\"ok\":true,\"available\":false,\"model\":\"qwen3:0.6b\",\"error\":\"ollama-unreachable\"}".utf8))
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.error, "ollama-unreachable")
        let failure = try JSONDecoder().decode(
            AiErrorResponse.self,
            from: Data("{\"ok\":false,\"error\":\"ollama-timeout\",\"message\":\"Local AI timed out\"}".utf8))
        XCTAssertEqual(failure.error, "ollama-timeout")
    }
}
