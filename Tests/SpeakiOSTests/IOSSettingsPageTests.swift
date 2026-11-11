#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Settings is split into sub-pages (#1470); search must still reach everything.
final class IOSSettingsPageTests: XCTestCase {
    func testEverySearchEntryOpensAPageOrTheAPIKeysScreen() {
        let entries = IOSSettingsSearch.catalogEntries(keyboardEnabled: true)
        let unreachable = entries.filter {
            IOSSettingsPage.page(for: $0) == nil && !IOSSettingsSearch.opensAPIKeys($0)
        }
        XCTAssertEqual(unreachable.map(\.id), [], "Add these section titles to an IOSSettingsPage")
    }

    func testEveryPageSectionHasASearchEntryOnOnePage() {
        var owners: [String: IOSSettingsPage] = [:]
        for page in IOSSettingsPage.allCases {
            for title in page.sectionTitles {
                XCTAssertNotNil(SettingsSearchCatalog.entry(title: title, platform: .iOS), title)
                XCTAssertNil(owners[title], "\(title) is listed on two pages")
                owners[title] = page
            }
        }
    }

    func testRootGroupsListEveryPageOnce() {
        let grouped = IOSSettingsPage.groups.flatMap { $0 }
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(IOSSettingsPage.allCases))
    }
}
#endif
