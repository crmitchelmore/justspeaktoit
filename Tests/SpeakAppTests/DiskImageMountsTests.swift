import XCTest
@testable import SpeakApp

final class DiskImageMountsTests: XCTestCase {
    func testPaths_onlyIncludesVolumesBackedByAnImage() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "images": [
                ["image-path": "/tmp/installer.dmg", "system-entities": [["mount-point": "/Volumes/Installer"]]],
                ["system-entities": [["mount-point": "/Volumes/External drive"]]]
            ]
        ], format: .xml, options: 0)
        XCTAssertEqual(DiskImageMounts.paths(from: data), ["/Volumes/Installer"])
        XCTAssertTrue(DiskImageMounts.paths(from: Data("invalid".utf8)).isEmpty)
    }

    func testImagePath_findsTheImageMountedAtThePoint() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "images": [
                ["system-entities": [["mount-point": "/Volumes/Installer"]]],
                ["image-path": "/tmp/other.dmg", "system-entities": [["mount-point": "/Volumes/Other"]]],
                ["image-path": "/tmp/installer.dmg", "system-entities": [["dev-entry": "/dev/disk9"],
                                                                        ["mount-point": "/Volumes/Installer"]]]
            ]
        ], format: .xml, options: 0)
        XCTAssertEqual(
            try DiskImageMounts.imagePath(mountedAt: "/Volumes/Installer", from: data), "/tmp/installer.dmg"
        )
        XCTAssertNil(try DiskImageMounts.imagePath(mountedAt: "/Volumes/Missing", from: data))
        XCTAssertThrowsError(
            try DiskImageMounts.imagePath(mountedAt: "/Volumes/Installer", from: Data("<plist><dict>".utf8))
        )
    }
}
