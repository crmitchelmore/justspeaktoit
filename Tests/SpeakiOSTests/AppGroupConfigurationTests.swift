#if os(iOS)
import Foundation
import XCTest

@testable import SpeakiOSLib

final class AppGroupConfigurationTests: XCTestCase {
    func testSharedStateUsesEntitledAppGroup() throws {
        let entitledGroups = try appGroups(
            in: repositoryRoot.appendingPathComponent("SpeakiOS.entitlements")
        )

        XCTAssertEqual(SharedTranscriptionState.appGroupIdentifier, "group.com.justspeaktoit.ios")
        XCTAssertTrue(entitledGroups.contains(SharedTranscriptionState.appGroupIdentifier))
    }

    func testWidgetUsesSameEntitledAppGroup() throws {
        let entitledGroups = try appGroups(
            in: repositoryRoot
                .appendingPathComponent("JustSpeakToItWidgetExtension")
                .appendingPathComponent("JustSpeakToItWidgetExtension.entitlements")
        )

        XCTAssertTrue(entitledGroups.contains(SharedTranscriptionState.appGroupIdentifier))
    }

    private func appGroups(in entitlementsURL: URL) throws -> [String] {
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let entitledGroups = try XCTUnwrap(
            plist["com.apple.security.application-groups"] as? [String]
        )

        return entitledGroups
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
#endif
