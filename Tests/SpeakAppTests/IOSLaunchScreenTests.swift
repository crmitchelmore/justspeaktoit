import Foundation
import XCTest

final class IOSLaunchScreenTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLaunchScreen_usesAnAdaptiveImageWithoutText() throws {
        let storyboard = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SpeakiOSApp/Resources/LaunchScreen.storyboard"),
            encoding: .utf8
        )

        XCTAssertTrue(storyboard.contains("image=\"LaunchMark\""))
        XCTAssertTrue(storyboard.contains("systemColor=\"systemBackgroundColor\""))
        XCTAssertFalse(storyboard.contains("<label"))
    }

    func testLaunchMark_hasLightAndDarkVectorVariants() throws {
        let imageSet = repositoryRoot.appendingPathComponent("SpeakiOSApp/Assets.xcassets/LaunchMark.imageset")
        let contents = try String(
            contentsOf: imageSet.appendingPathComponent("Contents.json"),
            encoding: .utf8
        )

        XCTAssertTrue(contents.contains("LaunchMark.svg"))
        XCTAssertTrue(contents.contains("LaunchMark-dark.svg"))
        XCTAssertTrue(contents.contains("preserves-vector-representation"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: imageSet.appendingPathComponent("LaunchMark.svg").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: imageSet.appendingPathComponent("LaunchMark-dark.svg").path)
        )
    }
}
