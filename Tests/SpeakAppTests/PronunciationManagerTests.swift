import XCTest
@testable import SpeakApp

@MainActor
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

  func testFreshStore_exposesAllDefaultEntries() {
    let manager = PronunciationManager(defaults: defaults)

    XCTAssertEqual(manager.entries.count, PronunciationEntry.defaultEntries.count)
    XCTAssertFalse(manager.entries.isEmpty)
  }

  func testSearchAndCategoryFiltering_keepVisibleEntriesAvailable() {
    let manager = PronunciationManager(defaults: defaults)

    XCTAssertTrue(manager.search("API").contains { $0.word == "API" })
    XCTAssertTrue(
      manager.entries(for: .technical).allSatisfy {
        $0.category == PronunciationEntry.Category.technical.rawValue
      }
    )
  }
}
