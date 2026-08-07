import XCTest
import SpeakCore

final class PronunciationManagerTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "PronunciationManagerTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = ""
    super.tearDown()
  }

  @MainActor
  func testFreshStore_exposesAllDefaultEntries() {
    let manager = PronunciationManager(defaults: defaults)

    XCTAssertEqual(manager.entries.count, PronunciationEntry.defaultEntries.count)
    XCTAssertFalse(manager.entries.isEmpty)
  }

  @MainActor
  func testSearchAndCategoryFiltering_keepVisibleEntriesAvailable() {
    let manager = PronunciationManager(defaults: defaults)
    let technicalEntries = manager.entries(for: .technical)

    XCTAssertTrue(manager.search("API").contains { $0.word == "API" })
    XCTAssertFalse(technicalEntries.isEmpty)
    XCTAssertTrue(
      technicalEntries.allSatisfy {
        $0.category == PronunciationEntry.Category.technical.rawValue
      }
    )
  }
}
