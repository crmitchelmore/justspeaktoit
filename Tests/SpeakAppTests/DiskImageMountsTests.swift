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
}
