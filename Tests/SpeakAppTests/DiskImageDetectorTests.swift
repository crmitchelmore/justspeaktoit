import XCTest

@testable import SpeakApp

/// The "Move to Applications?" prompt must only fire for bundles that really
/// run from an installer image, never for builds that merely live on an
/// external or secondary volume.
final class DiskImageDetectorTests: XCTestCase {

    func testApplicationsFolderIsNeverADiskImage() {
        let url = URL(fileURLWithPath: "/Applications/JustSpeakToIt.app")
        XCTAssertFalse(DiskImageDetector.isRunningFromDiskImage(bundleURL: url, volumeIsReadOnly: { _ in true }))
    }

    func testAppTranslocationMountIsADiskImage() {
        let url = URL(
            fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/JustSpeakToIt.app"
        )
        XCTAssertTrue(DiskImageDetector.isRunningFromDiskImage(bundleURL: url, volumeIsReadOnly: { _ in false }))
    }

    func testReadOnlyMountedVolumeIsADiskImage() {
        let url = URL(fileURLWithPath: "/Volumes/Just Speak to It/JustSpeakToIt.app")
        XCTAssertTrue(DiskImageDetector.isRunningFromDiskImage(bundleURL: url, volumeIsReadOnly: { _ in true }))
    }

    func testWritableExternalVolumeIsNotADiskImage() {
        let url = URL(fileURLWithPath: "/Volumes/Memory/cache/xcode-derived/Build/Products/Debug/JustSpeakToIt.app")
        XCTAssertFalse(DiskImageDetector.isRunningFromDiskImage(bundleURL: url, volumeIsReadOnly: { _ in false }))
    }

    func testUnknownVolumeStateIsNotADiskImage() {
        let url = URL(fileURLWithPath: "/Volumes/Missing/JustSpeakToIt.app")
        XCTAssertFalse(DiskImageDetector.isRunningFromDiskImage(bundleURL: url, volumeIsReadOnly: { _ in nil }))
    }

    func testOtherLocationsAreNotADiskImage() {
        let url = URL(fileURLWithPath: "/Users/someone/Downloads/JustSpeakToIt.app")
        XCTAssertFalse(DiskImageDetector.isRunningFromDiskImage(bundleURL: url, volumeIsReadOnly: { _ in true }))
    }
}
