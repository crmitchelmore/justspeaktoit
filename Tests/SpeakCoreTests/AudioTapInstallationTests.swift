#if canImport(AVFoundation)
import AVFoundation
import SpeakCore
import XCTest

final class AudioTapInstallationTests: XCTestCase {
    func testInstallTapSafely_installsTapOnFreeBus() throws {
        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        defer { engine.detach(mixer) }

        try mixer.installTapSafely(onBus: 0, bufferSize: 1_024, format: nil) { _, _ in }
        mixer.removeTap(onBus: 0)
    }

    func testInstallTapSafely_duplicateTapThrowsInsteadOfAborting() throws {
        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        defer {
            mixer.removeTap(onBus: 0)
            engine.detach(mixer)
        }

        try mixer.installTapSafely(onBus: 0, bufferSize: 1_024, format: nil) { _, _ in }

        XCTAssertThrowsError(
            try mixer.installTapSafely(onBus: 0, bufferSize: 1_024, format: nil) { _, _ in }
        ) { error in
            guard let tapError = error as? AudioTapInstallationError else {
                return XCTFail("Expected AudioTapInstallationError, got \(error)")
            }
            XCTAssertFalse(tapError.reason.isEmpty)
            XCTAssertNotNil(tapError.errorDescription)
        }
    }
}
#endif
