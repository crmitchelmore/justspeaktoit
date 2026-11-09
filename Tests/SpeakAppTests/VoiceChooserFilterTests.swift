import SpeakCore
import XCTest

@testable import SpeakApp

final class VoiceChooserFilterTests: XCTestCase {
  private let voices = [
    TTSVoice(id: "openai/zara", name: "Zara", provider: .openai,
             traits: [.female, .british], previewURL: nil),
    TTSVoice(id: "openai/alex", name: "Alex", provider: .openai,
             traits: [.male, .american], previewURL: nil),
    TTSVoice(id: "system/sam", name: "Sam", provider: .system,
             traits: [.neutral], previewURL: nil),
    TTSVoice(id: "elevenlabs/bella", name: "Bella", provider: .elevenlabs,
             traits: [.female, .british], previewURL: nil)
  ]

  func testSearch_MatchesNameProviderAndMultipleTraits() {
    for (query, expected) in [
      ("ZARA", ["openai/zara"]),
      ("openai", ["openai/alex", "openai/zara"]),
      (" british FEMALE ", ["elevenlabs/bella", "openai/zara"]),
      ("openai british", ["openai/zara"])
    ] {
      var filter = VoiceChooserFilter()
      filter.query = query
      XCTAssertEqual(ids(filter), expected)
    }
  }

  func testProviderFilter_OnlyIncludesChosenProvider() {
    var filter = VoiceChooserFilter()
    filter.provider = .openai
    XCTAssertEqual(ids(filter), ["openai/alex", "openai/zara"])
  }

  func testUsableOnly_KeepsMissingCurrentVoicePinnedDespiteOtherFilters() {
    var filter = VoiceChooserFilter()
    filter.usableOnly = true
    XCTAssertEqual(ids(filter), ["system/sam", "openai/alex"])
    filter.query = "no match"
    filter.provider = .system
    filter.gender = .male
    XCTAssertEqual(filter.pinnedVoice(in: voices, selection: "openai/zara")?.id, "openai/zara")
    XCTAssertTrue(filter.groups(in: voices, selection: "openai/zara", availability: availability).isEmpty)
  }

  func testGenderFilter_MatchesExactTrait() {
    for (gender, expected) in [
      (VoiceChooserFilter.Gender.female, ["elevenlabs/bella", "openai/zara"]),
      (.male, ["openai/alex"]),
      (.neutral, ["system/sam"])
    ] {
      var filter = VoiceChooserFilter()
      filter.gender = gender
      XCTAssertEqual(ids(filter), expected)
    }
  }

  func testGrouping_OrdersProvidersAndNamesAndOmitsPinnedDuplicate() {
    let filter = VoiceChooserFilter()
    let groups = filter.groups(in: Array(voices.reversed()), selection: "", availability: availability)
    XCTAssertEqual(groups.map(\.provider), [.elevenlabs, .system, .openai])
    XCTAssertEqual(groups.last?.voices.map(\.name), ["Alex", "Zara"])
    XCTAssertEqual(ids(filter, selection: "openai/alex"), ["elevenlabs/bella", "system/sam", "openai/zara"])
  }

  func testEmptyAndUnmatchedInputs_ReturnNoGroups() {
    var filter = VoiceChooserFilter()
    XCTAssertTrue(filter.groups(in: [], selection: "missing", availability: availability).isEmpty)
    XCTAssertNil(filter.pinnedVoice(in: [], selection: "missing"))
    filter.query = "nonexistent"
    XCTAssertTrue(ids(filter).isEmpty)
  }

  func testAvailability_MissingIsNotUsable() {
    XCTAssertFalse(VoiceChooserFilter.isUsable(.missing(providerName: "OpenAI")))
    XCTAssertTrue(VoiceChooserFilter.isUsable(.ready(providerName: "OpenAI")))
    XCTAssertTrue(VoiceChooserFilter.isUsable(.notRequired))
  }

  private func ids(_ filter: VoiceChooserFilter, selection: String = "") -> [String] {
    filter.groups(in: voices, selection: selection, availability: availability).flatMap { $0.voices.map(\.id) }
  }

  private func availability(_ voice: TTSVoice) -> ModelCredentialAvailability {
    if voice.provider == .system { return .notRequired }
    if voice.id == "openai/alex" { return .ready(providerName: "OpenAI") }
    return .missing(providerName: voice.provider.displayName)
  }
}
