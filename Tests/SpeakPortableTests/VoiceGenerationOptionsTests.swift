import Foundation
import XCTest
import SpeakCore

final class VoiceGenerationOptionsTests: XCTestCase {
    func testGenerationOptions_UseOneLosslessNativePayloadAndRejectUnknownFlags() throws {
        for flags in Int32(0)...Int32(3) {
            XCTAssertEqual(try XCTUnwrap(VoiceGenerationOptions(nativeFlags: flags)).nativeFlags, flags)
        }
        XCTAssertNil(VoiceGenerationOptions(nativeFlags: -1))
        XCTAssertNil(VoiceGenerationOptions(nativeFlags: 4))
    }
}
