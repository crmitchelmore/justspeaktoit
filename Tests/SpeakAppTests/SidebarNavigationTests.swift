import XCTest

@testable import SpeakApp

/// Coverage for the sidebar's keyboard-traversal order and per-row
/// accessibility identifiers (issue #831).
///
/// `SideBarView` hands selection to its `List`, so the arrow keys walk exactly
/// `SidebarItem.orderedItems`. Asserting on that array keeps the traversal
/// contract — including the jump across the section boundary — testable
/// without rendering the view.
final class SidebarNavigationTests: XCTestCase {
    func testOrderedItems_coverEverySidebarRowInDisplayOrder() {
        XCTAssertEqual(
            SidebarItem.speakItems,
            [.dashboard, .history, .voiceOutput, .corrections, .troubleshooting]
        )
        XCTAssertEqual(
            SidebarItem.settingsItems,
            SettingsTab.allCases.map(SidebarItem.settings)
        )
        XCTAssertEqual(
            SidebarItem.orderedItems,
            SidebarItem.speakItems + SidebarItem.settingsItems
        )
    }

    func testOrderedItems_crossTheSectionBoundaryWithoutAGap() {
        let items = SidebarItem.orderedItems
        guard let boundary = items.firstIndex(of: .troubleshooting) else {
            return XCTFail("Troubleshooting should be a sidebar row")
        }

        // Down arrow from the last Speak row lands on the first Settings row,
        // and up arrow from there comes straight back.
        XCTAssertEqual(items[boundary], SidebarItem.speakItems.last)
        XCTAssertEqual(items[items.index(after: boundary)], .settings(.general))
        XCTAssertEqual(items[items.index(before: boundary)], .corrections)
        XCTAssertEqual(items.last, .settings(.about))
    }

    func testEveryRow_exposesAStableUniqueAccessibilityIdentifier() {
        var seen: Set<String> = []
        for item in SidebarItem.orderedItems {
            let identifier = item.accessibilityID
            XCTAssertFalse(
                identifier.isEmpty,
                "\(item) should expose an accessibility identifier"
            )
            XCTAssertTrue(
                identifier.hasPrefix("sidebar"),
                "\(item) identifier \(identifier) should be namespaced to the sidebar"
            )
            XCTAssertTrue(
                seen.insert(identifier).inserted,
                "\(item) reuses accessibility identifier \(identifier)"
            )
        }
        XCTAssertEqual(seen.count, SidebarItem.orderedItems.count)
    }

    func testSpeakRowIdentifiers_matchTheirDocumentedNames() {
        XCTAssertEqual(SidebarItem.dashboard.accessibilityID, "sidebarDashboard")
        XCTAssertEqual(SidebarItem.history.accessibilityID, "sidebarHistory")
        XCTAssertEqual(SidebarItem.voiceOutput.accessibilityID, "sidebarVoiceOutput")
        XCTAssertEqual(SidebarItem.corrections.accessibilityID, "sidebarCorrections")
        XCTAssertEqual(SidebarItem.troubleshooting.accessibilityID, "sidebarTroubleshooting")
    }

    func testSettingsRowIdentifiers_carryTheirTabRawValue() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(
                SidebarItem.settings(tab).accessibilityID,
                "sidebarSettings-\(tab.rawValue)"
            )
        }
    }

    func testEveryRow_hasATitleAnHelpMessageAndAnIcon() {
        for item in SidebarItem.orderedItems {
            XCTAssertFalse(item.title(isAssemblyAI: false).isEmpty, "\(item) needs a title")
            XCTAssertFalse(item.title(isAssemblyAI: true).isEmpty, "\(item) needs a title")
            XCTAssertFalse(item.helpMessage.isEmpty, "\(item) needs a help message")
            XCTAssertFalse(item.systemImage.isEmpty, "\(item) needs an icon")
        }
    }

    /// The AssemblyAI-dependent tab title is the one row label that changes at
    /// runtime; the row builder reads it through `title(isAssemblyAI:)`.
    func testPostProcessingRowTitle_followsTheActiveLiveModel() {
        let item = SidebarItem.settings(.postProcessing)
        XCTAssertEqual(item.title(isAssemblyAI: false), "Post-processing")
        XCTAssertEqual(item.title(isAssemblyAI: true), "Pre-processing")
    }
}
