import SpeakCore
import XCTest

@testable import SpeakApp

final class ModelPickerSelectionTests: XCTestCase {
  private let options = [
    ModelCatalog.Option(id: "openai/gpt-4o-mini", displayName: "GPT-4o mini"),
    ModelCatalog.Option(id: "openai/gpt-4o", displayName: "GPT-4o")
  ]

  func testInitial_matchesAnOptionCaseInsensitivelyWithoutRepair() {
    let state = ModelPickerSelection.initial(for: " OpenAI/GPT-4o ", options: options, allowsCustom: true)
    XCTAssertEqual(state, .init(selection: "openai/gpt-4o", customValue: ""))
  }

  func testInitial_repairsAnEmptyValueToTheFirstOption() {
    let state = ModelPickerSelection.initial(for: "  ", options: options, allowsCustom: true)
    XCTAssertEqual(
      state, .init(selection: "openai/gpt-4o-mini", customValue: "", replacementValue: "openai/gpt-4o-mini")
    )
  }

  func testInitial_showsAnUnknownValueAsCustomWhenAllowed() {
    let state = ModelPickerSelection.initial(for: " acme/model ", options: options, allowsCustom: true)
    XCTAssertEqual(state, .init(selection: ModelCatalog.customOptionID, customValue: "acme/model"))
  }

  func testInitial_repairsAnUnknownValueWhenCustomIsNotAllowed() {
    let state = ModelPickerSelection.initial(for: "acme/model", options: options, allowsCustom: false)
    XCTAssertEqual(state.replacementValue, "openai/gpt-4o-mini")
    XCTAssertEqual(
      ModelPickerSelection.initial(for: "acme/model", options: [], allowsCustom: false),
      .init(selection: "", customValue: "")
    )
  }

  func testSynced_reflectsAnEmptyValueAsCustomInsteadOfRepairing() {
    let state = ModelPickerSelection.synced(
      with: "", options: options, allowsCustom: true, repairsInvalidValue: true
    )
    XCTAssertEqual(state, .init(selection: ModelCatalog.customOptionID, customValue: ""))
  }

  func testSynced_repairsOnlyWhenAskedAndCustomIsNotAllowed() {
    let reflected = ModelPickerSelection.synced(
      with: "acme/model", options: options, allowsCustom: false, repairsInvalidValue: false
    )
    let repaired = ModelPickerSelection.synced(
      with: "acme/model", options: options, allowsCustom: false, repairsInvalidValue: true
    )
    XCTAssertEqual(reflected, .init(selection: "", customValue: ""))
    XCTAssertEqual(repaired.replacementValue, "openai/gpt-4o-mini")
  }

  func testContextLengthLabel_usesThousandsAndMillions() {
    XCTAssertEqual(ModelContextLength.label(128_000), "128k ctx")
    XCTAssertEqual(ModelContextLength.label(2_000_000), "2M ctx")
  }
}
