import XCTest
@testable import VanguardApple

final class LocaleSelectionTests: XCTestCase {
    private func transcript(_ text: String, _ confidences: [Float]) -> LocalTranscript {
        LocalTranscript(originalText: text, segmentConfidences: confidences, engine: "SFSpeechRecognizer/on-device", runtime: "test")
    }
    private let en = Locale(identifier: "en-US"), fil = Locale(identifier: "fil-PH")

    func testTheMoreConfidentLocaleWinsSoFilipinoSpeechIsNotForcedThroughEnglish() async throws {
        let result = try await LocaleSelection.best(locales: [en, fil]) { locale in
            locale == self.en ? self.transcript("nahee heerapan see yang hoominga", [0.2, 0.3]) : self.transcript("nahihirapan siyang huminga", [0.9, 0.85])
        }
        XCTAssertEqual(result.locale, fil); XCTAssertEqual(result.transcript.originalText, "nahihirapan siyang huminga")
    }

    func testEnglishWinsWhenItIsMoreConfident() async throws {
        let result = try await LocaleSelection.best(locales: [en, fil]) { locale in
            locale == self.en ? self.transcript("chest pain and shortness of breath", [0.95, 0.9]) : self.transcript("chest pain and shortness of breath", [0.4])
        }
        XCTAssertEqual(result.locale, en)
    }

    func testAnUnavailableLocaleIsSkippedNotFatal() async throws {
        let result = try await LocaleSelection.best(locales: [en, fil]) { locale in
            if locale == self.fil { throw TranscriptionFailure.onDeviceUnavailable }
            return self.transcript("male sixty years old", [0.8])
        }
        XCTAssertEqual(result.locale, en)
    }

    func testWhenNoLocaleWorksTheRealReasonIsReportedAndNothingFallsBackToTheCloud() async {
        do {
            _ = try await LocaleSelection.best(locales: [en, fil]) { _ in throw TranscriptionFailure.onDeviceUnavailable }
            XCTFail("No transcript should be produced")
        } catch TranscriptionFailure.onDeviceUnavailable {} catch { XCTFail("\(error)") }
        do {
            _ = try await LocaleSelection.best(locales: [en]) { _ in throw TranscriptionFailure.permissionRequired }
            XCTFail("No transcript should be produced")
        } catch TranscriptionFailure.permissionRequired {} catch { XCTFail("\(error)") }
    }

    func testCancellationStopsTheSearchAndIsNotSwallowed() async {
        let task = Task { try await LocaleSelection.best(locales: [self.en, self.fil]) { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return self.transcript("x", [1]) } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testDefaultLocalesCoverEnglishAndFilipino() {
        XCTAssertEqual(LocaleSelection.defaultLocales.map(\.identifier), ["en-US", "fil-PH"])
    }
}
