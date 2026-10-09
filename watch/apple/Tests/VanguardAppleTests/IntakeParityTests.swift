import XCTest
@testable import VanguardApple

/// The fixture is generated from `hub/rag/knowledge.js` and `hub/intake.js` (hub/intake-parity.test.js).
final class IntakeParityTests: XCTestCase {
    private struct Case: Decodable {
        struct Match: Decodable { let id: String; let matched: String; let negated: Bool }
        struct Fields: Decodable { let location: String?; let patientCount: Int?; let ageGroup: String; let etaMinutes: Int? }
        let transcript: String; let matches: [Match]; let fields: Fields
        let evidence: [String: String?]; let locationBasis: String?; let notes: [String]
    }
    private struct Fixture: Decodable { let packVersion: String; let cases: [Case] }
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..") }

    func testBundledPackIsIdenticalToTheHubPack() throws {
        let hub = try Data(contentsOf: root.appendingPathComponent("hub/rag/medical_terms.json"))
        let bundled = try Data(contentsOf: root.appendingPathComponent("watch/apple/Sources/VanguardApple/Resources/medical_terms.json"))
        XCTAssertEqual(hub, bundled, "copy hub/rag/medical_terms.json into Sources/VanguardApple/Resources when the pack changes")
        let pack = try TermPack.bundled()
        XCTAssertEqual(pack.reviewStatus, "unreviewed-draft")
        XCTAssertGreaterThanOrEqual(pack.entries.count, 1200)
    }

    func testSwiftMatchesTheHubForEveryFixtureTranscript() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("docs/fixtures/intake-parity-v1.json")))
        let pack = try TermPack.bundled()
        XCTAssertEqual(pack.packVersion, fixture.packVersion)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 60)
        for item in fixture.cases {
            let matches = pack.retrieve(item.transcript, limit: 12).map { Case.Match(id: $0.id, matched: $0.matched, negated: $0.negated) }
            XCTAssertEqual(matches.map(\.id), item.matches.map(\.id), "term ids for: \(item.transcript)")
            XCTAssertEqual(matches.map(\.matched), item.matches.map(\.matched), "matched phrases for: \(item.transcript)")
            XCTAssertEqual(matches.map(\.negated), item.matches.map(\.negated), "negation for: \(item.transcript)")
            let result = DeterministicIntake.extract(from: item.transcript, pack: pack)
            XCTAssertEqual(result.details.location, item.fields.location, "location for: \(item.transcript)")
            XCTAssertEqual(result.details.patientCount, item.fields.patientCount, "count for: \(item.transcript)")
            XCTAssertEqual(result.details.ageGroup, item.fields.ageGroup, "age group for: \(item.transcript)")
            XCTAssertEqual(result.details.etaMinutes, item.fields.etaMinutes, "ETA for: \(item.transcript)")
            XCTAssertEqual(result.evidence, item.evidence.compactMapValues { $0 }, "evidence for: \(item.transcript)")
            XCTAssertEqual(result.locationBasis, item.locationBasis, "location basis for: \(item.transcript)")
            XCTAssertEqual(result.notes, item.notes, "notes for: \(item.transcript)")
        }
    }

    func testFindingsQuoteTheTranscriptAndSkipDeniedTerms() throws {
        let pack = try TermPack.bundled()
        let transcript = "May lalaki po dito, nahihirapan huminga at masakit yung dibdib niya. Walang lagnat."
        let result = DeterministicIntake.extract(from: transcript, pack: pack)
        let findings = DeterministicIntake.findings(for: transcript, terms: result.terms)
        XCTAssertFalse(findings.isEmpty)
        XCTAssertTrue(findings.allSatisfy { transcript.contains($0.excerpt!) && $0.source == "reported" && $0.kind == "symptom" })
        XCTAssertFalse(findings.map(\.name).contains("fever"), "a denied symptom is not reported")
        XCTAssertFalse(findings.contains { $0.kind == "vital" }, "no vital signs are invented")
    }
}
