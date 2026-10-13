import SpeakCore
import XCTest

final class SpeechGenerationDefaultsTests: XCTestCase {
    func testGeneratedSpeechDefaults_MatchCanonicalMacPreferences() {
        XCTAssertTrue(SpeechGenerationDefaults.autoPlay)
        XCTAssertFalse(SpeechGenerationDefaults.saveToRecordings)
    }
}
