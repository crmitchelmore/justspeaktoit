import XCTest

@testable import SpeakApp

/// The Microphone card's "Currently active" line used to print the system default
/// device unconditionally, so a user who had picked another microphone was told the
/// wrong device was live (issue #852).
@MainActor
final class AudioInputDeviceLabelTests: XCTestCase {
  private func device(id: String, name: String, isDefault: Bool = false) -> AudioInputDeviceManager.Device {
    AudioInputDeviceManager.Device(
      id: id,
      deviceID: 0,
      name: name,
      manufacturer: "",
      channelCount: 1,
      nominalSampleRate: 48_000,
      isDefault: isDefault
    )
  }

  func testSelectedDevice_isNamedInsteadOfTheSystemDefault() {
    let devices = [
      device(id: "builtin", name: "MacBook Pro Microphone", isDefault: true),
      device(id: "usb", name: "Shure MV7")
    ]

    XCTAssertEqual(
      AudioInputDeviceManager.activeDeviceLabel(
        selectedUID: "usb",
        systemDefaultDisplayName: "MacBook Pro Microphone",
        devices: devices
      ),
      "Shure MV7"
    )
  }

  func testSystemDefaultSelection_isLabelledAsSuch() {
    let devices = [device(id: "builtin", name: "MacBook Pro Microphone", isDefault: true)]

    XCTAssertEqual(
      AudioInputDeviceManager.activeDeviceLabel(
        selectedUID: nil,
        systemDefaultDisplayName: "MacBook Pro Microphone",
        devices: devices
      ),
      "System Default (MacBook Pro Microphone)"
    )
  }

  func testUnknownSystemDefault_isNotWrappedInItsOwnName() {
    XCTAssertEqual(
      AudioInputDeviceManager.activeDeviceLabel(
        selectedUID: nil,
        systemDefaultDisplayName: AudioInputDeviceManager.unknownSystemDefaultDisplayName,
        devices: []
      ),
      AudioInputDeviceManager.unknownSystemDefaultDisplayName
    )
  }

  func testDisconnectedSelection_fallsBackToTheLabelledSystemDefault() {
    let devices = [device(id: "builtin", name: "MacBook Pro Microphone", isDefault: true)]

    XCTAssertEqual(
      AudioInputDeviceManager.activeDeviceLabel(
        selectedUID: "unplugged-usb",
        systemDefaultDisplayName: "MacBook Pro Microphone",
        devices: devices
      ),
      "System Default (MacBook Pro Microphone)"
    )
  }

  func testManufacturerQualifiedName_isUsedForTheSelectedDevice() {
    let devices = [
      AudioInputDeviceManager.Device(
        id: "usb",
        deviceID: 0,
        name: "MV7",
        manufacturer: "Shure",
        channelCount: 1,
        nominalSampleRate: 48_000,
        isDefault: false
      )
    ]

    XCTAssertEqual(
      AudioInputDeviceManager.activeDeviceLabel(
        selectedUID: "usb",
        systemDefaultDisplayName: "MacBook Pro Microphone",
        devices: devices
      ),
      "MV7 (Shure)"
    )
  }
}
