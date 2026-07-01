import XCTest

@testable import SpeakiOSLib

final class AudioSessionDiagnosticsTests: XCTestCase {

    // MARK: - FourCC decoding

    func testFourCharCode_cannotStartRecording_decodesToBangRec() {
        // Arrange
        let code = 561_145_187 // '!rec'

        // Act
        let fourCC = AudioSessionConfigurationError.fourCharCode(from: code)

        // Assert
        XCTAssertEqual(fourCC, "!rec")
    }

    func testFourCharCode_siriIsRecording_decodesToSiri() {
        // Arrange
        let code = 1_936_290_409 // 'siri'

        // Act
        let fourCC = AudioSessionConfigurationError.fourCharCode(from: code)

        // Assert
        XCTAssertEqual(fourCC, "siri")
    }

    func testFourCharCode_negativeParamError_isNotAFourCC() {
        // Arrange
        let code = -50 // kAudio_ParamError, not a printable FourCC

        // Act
        let fourCC = AudioSessionConfigurationError.fourCharCode(from: code)

        // Assert
        XCTAssertNil(fourCC)
    }

    // MARK: - Known error names

    func testKnownErrorName_bangRec_mapsToCannotStartRecording() {
        // Arrange
        let fourCC = "!rec"

        // Act
        let name = AudioSessionConfigurationError.knownErrorName(forFourCC: fourCC)

        // Assert
        XCTAssertEqual(name, "cannotStartRecording")
    }

    func testKnownErrorName_unknownFourCC_isNil() {
        // Arrange
        let fourCC = "zzzz"

        // Act
        let name = AudioSessionConfigurationError.knownErrorName(forFourCC: fourCC)

        // Assert
        XCTAssertNil(name)
    }

    // MARK: - Error description composition

    func testErrorDescription_setActiveInsufficientPriority_surfacesCodeAndState() {
        // Arrange
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: 561_017_449) // '!pri'
        let diagnostics = AudioSessionDiagnostics(
            category: "AVAudioSessionCategoryPlayAndRecord",
            mode: "AVAudioSessionModeMeasurement",
            options: "allowBluetooth,defaultToSpeaker",
            isOtherAudioPlaying: true,
            inputRoute: "None",
            outputRoute: "Speaker"
        )
        let error = AudioSessionConfigurationError(
            operation: .setActive,
            underlying: underlying,
            diagnostics: diagnostics
        )

        // Act
        let description = error.errorDescription ?? ""

        // Assert
        XCTAssertTrue(description.contains("setActive"), description)
        XCTAssertTrue(description.contains("insufficientPriority"), description)
        XCTAssertTrue(description.contains("'!pri'"), description)
        XCTAssertTrue(description.contains("561017449"), description)
        XCTAssertTrue(description.contains("otherAudioPlaying=true"), description)
    }

    func testErrorDescription_nonFourCCCode_stillSurfacesRawCode() {
        // Arrange
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -50)
        let diagnostics = AudioSessionDiagnostics(
            category: "AVAudioSessionCategoryPlayAndRecord",
            mode: "AVAudioSessionModeMeasurement",
            options: "none",
            isOtherAudioPlaying: false,
            inputRoute: "MicrophoneBuiltIn",
            outputRoute: "Speaker"
        )
        let error = AudioSessionConfigurationError(
            operation: .setCategory,
            underlying: underlying,
            diagnostics: diagnostics
        )

        // Act
        let description = error.errorDescription ?? ""

        // Assert
        XCTAssertTrue(description.contains("setCategory"), description)
        XCTAssertTrue(description.contains("code -50"), description)
        XCTAssertFalse(
            description.contains("'"),
            "Non-FourCC codes should not render quoted characters: \(description)"
        )
    }

    // MARK: - Summary

    func testSummary_includesAllCapturedFields() {
        // Arrange
        let diagnostics = AudioSessionDiagnostics(
            category: "cat",
            mode: "mode",
            options: "allowBluetooth",
            isOtherAudioPlaying: true,
            inputRoute: "in",
            outputRoute: "out"
        )

        // Act
        let summary = diagnostics.summary

        // Assert
        XCTAssertEqual(
            summary,
            "category=cat mode=mode options=[allowBluetooth] otherAudioPlaying=true input=in output=out"
        )
    }
}
