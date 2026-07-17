#if os(iOS)
import Foundation
import XCTest

@testable import SpeakiOSLib

final class AppGroupConfigurationTests: XCTestCase {
    func testSharedStateUsesEntitledAppGroup() throws {
        let entitledGroups = try appGroups(inResourceNamed: "SpeakiOS")

        XCTAssertEqual(SharedTranscriptionState.appGroupIdentifier, "group.com.justspeaktoit.ios")
        XCTAssertTrue(entitledGroups.contains(SharedTranscriptionState.appGroupIdentifier))
    }

    func testWidgetUsesSameEntitledAppGroup() throws {
        let entitledGroups = try appGroups(inResourceNamed: "JustSpeakToItWidgetExtension")

        XCTAssertTrue(entitledGroups.contains(SharedTranscriptionState.appGroupIdentifier))
    }

    private func appGroups(inResourceNamed resourceName: String) throws -> [String] {
        let entitlementsURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: resourceName, withExtension: "entitlements")
        )
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let entitledGroups = try XCTUnwrap(
            plist["com.apple.security.application-groups"] as? [String]
        )

        return entitledGroups
    }
}
#endif
