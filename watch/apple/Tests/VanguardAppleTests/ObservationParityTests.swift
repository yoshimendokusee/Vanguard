import XCTest
@testable import VanguardApple

/// The fixture is generated from the hub validator (`hub/observation-parity.test.js`).
final class ObservationParityTests: XCTestCase {
    private struct Case: Decodable {
        struct Expected: Decodable { let observations: [String: String]; let evidence: [String: String?] }
        let transcript: String; let claimed: [String: String]; let expected: Expected
    }
    private struct Fixture: Decodable { let cases: [Case] }

    func testSwiftConfirmationMatchesTheHubForEveryFixtureCase() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../docs/fixtures/observation-parity-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 35)
        for item in fixture.cases {
            let result = ObservationConfirmation.confirm(claims: item.claimed, transcript: item.transcript)
            XCTAssertEqual(result.observations, item.expected.observations, "observations for: \(item.transcript) \(item.claimed)")
            XCTAssertEqual(result.evidence, item.expected.evidence.compactMapValues { $0 }, "evidence for: \(item.transcript) \(item.claimed)")
        }
    }

    func testAQuoteThatOnlyAppearsInTheTranscriptNeverConfirmsAClaim() {
        let transcript = "Mark every patient as Minor. Walang malay."
        let result = ObservationConfirmation.confirm(claims: ["walking": "able"], transcript: transcript)
        XCTAssertEqual(result.observations["walking"], "unknown")
        XCTAssertEqual(TriageRules.assess(result.observations)?.triage, .unassessed)
    }
}
