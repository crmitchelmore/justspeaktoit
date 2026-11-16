import SpeakCore
import XCTest

final class PreferredAudioInputTests: XCTestCase {
    func testResolution_NoSavedChoice_UsesSystemDefault() {
        XCTAssertEqual(PreferredAudioInputResolution(storedUID: nil, availableUIDs: ["a"]), .systemDefault)
        XCTAssertEqual(PreferredAudioInputResolution(storedUID: "", availableUIDs: [""]), .systemDefault)
    }

    func testResolution_ConnectedChoice_IsApplied() {
        let resolution = PreferredAudioInputResolution(storedUID: "usb-1", availableUIDs: ["built-in", "usb-1"])
        XCTAssertEqual(resolution, .selected(uid: "usb-1"))
        XCTAssertEqual(resolution.uidToApply, "usb-1")
        XCTAssertFalse(resolution.isFallback)
    }

    func testResolution_DisconnectedChoice_FallsBackVisibly() {
        let resolution = PreferredAudioInputResolution(storedUID: "headset", availableUIDs: ["built-in"])
        XCTAssertEqual(resolution, .unavailable(uid: "headset"))
        XCTAssertNil(resolution.uidToApply)
        XCTAssertTrue(resolution.isFallback)
        XCTAssertEqual(
            PreferredAudioInputResolution.fallbackNotice(currentInputName: "Built-in Microphone"),
            "Your chosen microphone isn't connected, so Built-in Microphone is used."
        )
        XCTAssertEqual(
            PreferredAudioInputResolution.fallbackNotice(currentInputName: ""),
            "Your chosen microphone isn't connected, so the system default is used."
        )
    }

    func testInputKind_MapsSystemPortTypes() {
        XCTAssertEqual(AudioInputKind(portType: "MicrophoneBuiltIn"), .builtIn)
        XCTAssertEqual(AudioInputKind(portType: "MicrophoneWired"), .wired)
        XCTAssertEqual(AudioInputKind(portType: "BluetoothHFP"), .bluetooth)
        XCTAssertEqual(AudioInputKind(portType: "BluetoothLE"), .bluetooth)
        XCTAssertEqual(AudioInputKind(portType: "USBAudio"), .usb)
        XCTAssertEqual(AudioInputKind(portType: "LineIn"), .lineIn)
        XCTAssertEqual(AudioInputKind(portType: "Speaker"), .other)
    }
}
