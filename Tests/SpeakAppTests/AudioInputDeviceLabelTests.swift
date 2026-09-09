import XCTest

@testable import SpeakApp

/// A microphone preference must distinguish a specific device from the macOS
/// default without implying that either is a verified live recording route (#852).
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
      AudioInputDeviceManager.preferredDeviceLabel(
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
      AudioInputDeviceManager.preferredDeviceLabel(
        selectedUID: nil,
        systemDefaultDisplayName: "MacBook Pro Microphone",
        devices: devices
      ),
      "macOS default (MacBook Pro Microphone)"
    )
  }

  func testUnknownSystemDefault_isNotWrappedInItsOwnName() {
    XCTAssertEqual(
      AudioInputDeviceManager.preferredDeviceLabel(
        selectedUID: nil,
        systemDefaultDisplayName: AudioInputDeviceManager.unknownSystemDefaultDisplayName,
        devices: []
      ),
      "macOS default (unavailable)"
    )
  }

  func testDisconnectedSelection_fallsBackToTheLabelledSystemDefault() {
    let devices = [device(id: "builtin", name: "MacBook Pro Microphone", isDefault: true)]

    XCTAssertEqual(
      AudioInputDeviceManager.preferredDeviceLabel(
        selectedUID: "unplugged-usb",
        systemDefaultDisplayName: "MacBook Pro Microphone",
        devices: devices
      ),
      "macOS default (MacBook Pro Microphone)"
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
      AudioInputDeviceManager.preferredDeviceLabel(
        selectedUID: "usb",
        systemDefaultDisplayName: "MacBook Pro Microphone",
        devices: devices
      ),
      "MV7 (Shure)"
    )
  }
}
