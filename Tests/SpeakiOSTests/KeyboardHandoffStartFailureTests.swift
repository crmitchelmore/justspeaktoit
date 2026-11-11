#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// A keyboard hand-off start that fails in the audio session must be
/// classified by the `AVAudioSession` code underneath the transcriber's
/// wrapping, or a background refusal is misreported (issue #1469).
@MainActor
final class KeyboardHandoffStartFailureTests: XCTestCase {
    private let refusal = NSError(domain: "NSOSStatusErrorDomain", code: 561_145_187) // '!rec'

    private func configurationError() -> AudioSessionConfigurationError {
        AudioSessionConfigurationError(
            operation: .setActive,
            underlying: refusal,
            diagnostics: AudioSessionManager.diagnostics(for: .sharedInstance())
        )
    }

    func testAudioCause_unwrapsTranscriberAndConfigurationErrors() {
        let wrapped = iOSTranscriptionError.audioSessionFailed(configurationError())
        let cause = KeyboardInstantDictationCoordinator.audioCause(of: wrapped) as NSError
        XCTAssertEqual(cause.code, refusal.code)
        XCTAssertEqual(
            KeyboardHandoffStartDiagnosis.failureCode(
                stage: .recording, error: cause, applicationIsInForeground: false
            ),
            .appUnavailable
        )
    }

    func testAudioCause_unwrapsBareConfigurationError() {
        let cause = KeyboardInstantDictationCoordinator.audioCause(of: configurationError()) as NSError
        XCTAssertEqual(cause.code, refusal.code)
    }

    func testAudioCause_leavesOtherErrorsAlone() {
        let other = NSError(domain: "provider", code: 7)
        XCTAssertEqual(KeyboardInstantDictationCoordinator.audioCause(of: other) as NSError, other)
    }
}
#endif
