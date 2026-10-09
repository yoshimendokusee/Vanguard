import XCTest
@testable import VanguardApple

/// The fixture is generated from `hub/risk.js` and covers every valid combination.
final class TriageParityTests: XCTestCase {
    private struct Case: Decodable { let observations: [String: String]; let expected: ProvisionalTriage }
    private struct Fixture: Decodable { let ruleVersion: String; let cases: [Case] }

    private func fixture() throws -> Fixture {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../docs/fixtures/triage-parity-v1.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }

    func testSwiftRulesMatchTheHubForEveryObservationCombination() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.ruleVersion, TriageRules.ruleVersion)
        XCTAssertEqual(fixture.cases.count, 4 * 3 * 3 * 3)
        for item in fixture.cases {
            XCTAssertEqual(TriageRules.assess(item.observations), item.expected, "\(item.observations)")
        }
    }

    func testUnknownNeverBecomesMinorAndInvalidInputIsRefused() {
        let unknown = ["breathing": "unknown", "consciousness": "unknown", "severeBleeding": "unknown", "walking": "unknown"]
        XCTAssertEqual(TriageRules.assess(unknown)?.triage, .unassessed)
        var almost = ["breathing": "normal", "consciousness": "alert", "severeBleeding": "absent", "walking": "able"]
        XCTAssertEqual(TriageRules.assess(almost)?.triage, .minor)
        almost["severeBleeding"] = "unknown"
        XCTAssertNotEqual(TriageRules.assess(almost)?.triage, .minor)
        almost["breathing"] = "invented"
        XCTAssertNil(TriageRules.assess(almost), "values outside the schema are refused, not guessed")
        XCTAssertNil(TriageRules.assess(["breathing": "normal"]))
    }
}
