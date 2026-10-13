import SpeakCore
import SpeakWindowsPlatform
import XCTest

final class WindowsRecordingFeedbackTests: XCTestCase {
    func testAllEightCanonicalAACAssets_DecodeWithInstalledMediaFoundation() async throws {
        try await WindowsRecordingFeedbackSelfTest.validateBundledAssets()
    }

    func testNativeRenderer_GainReplayCancellationAndDeviceFailure() async throws {
        try await WindowsRecordingFeedbackSelfTest.validateRenderer()
    }
}
