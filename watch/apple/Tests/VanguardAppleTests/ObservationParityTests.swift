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
    func testCirculationRequiresExplicitRadialPulseEvidenceAndDoesNotChangeTriage() throws {
        for (text, expected) in [
            ("Synthetic: radial pulse present.", "present"),
            ("Synthetic: no palpable radial pulse.", "absent"),
            ("Synthetic: may pulso sa pulsuhan.", "present"),
            ("Synthetic: not radial pulse present.", "unknown"),
            ("Synthetic: radial pulse present but radial pulse absent.", "unknown"),
            ("Synthetic: pulse present.", "unknown"),
        ] {
            let result = ObservationConfirmation.circulation(in: text)
            XCTAssertEqual(result.value, expected)
            if let quote = result.quote { XCTAssertTrue(text.contains(quote)) }
            let observations = ["breathing": "normal", "consciousness": "alert", "severeBleeding": "absent", "walking": "able", "circulation": result.value]
            XCTAssertEqual(TriageRules.assess(observations)?.triage, .minor, "no new pulse scoring rule")
        }
    }

    func testExplicitConfusionRemainsProvisionalWithoutANewUrgencyRule() {
        let result = ObservationConfirmation.confirm(claims: [:], transcript: "Synthetic patient is confused.")
        XCTAssertEqual(result.observations["consciousness"], "confused")
        XCTAssertEqual(TriageRules.assess(result.observations)?.triage, .unassessed)
    }

}
