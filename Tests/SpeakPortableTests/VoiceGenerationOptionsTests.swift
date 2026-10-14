import XCTest
import SpeakCore

final class VoiceGenerationOptionsTests: XCTestCase {
    func testGenerationOptions_UseOneLosslessNativePayloadAndRejectUnknownFlags() throws {
        for flags in Int32(0)...Int32(3) {
            let options = try XCTUnwrap(VoiceGenerationOptions(nativeFlags: flags))
            XCTAssertEqual(options.nativeFlags, flags)
            XCTAssertEqual(options.autoPlay, flags & 1 != 0)
            XCTAssertEqual(options.saveToRecordings, flags & 2 != 0)
        }
        XCTAssertNil(VoiceGenerationOptions(nativeFlags: -1))
        XCTAssertNil(VoiceGenerationOptions(nativeFlags: 4))
    }
}

