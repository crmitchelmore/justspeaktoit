import SpeakCore
import Foundation

/// What `ModelPicker` shows for a bound model identifier: the matching option,
/// the Custom… entry with its text, or nothing; plus a replacement when the
/// bound value is invalid and the picker should repair it.
struct ModelPickerSelection: Equatable {
  var selection: String
  var customValue: String
  /// The value to write back to the binding, or nil to leave it alone.
  var replacementValue: String?

  /// The state a newly created picker starts in. An empty value, or one a
  /// custom-less picker cannot show, is replaced by the first option.
  static func initial(
    for value: String,
    options: [ModelCatalog.Option],
    allowsCustom: Bool
  ) -> ModelPickerSelection {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = match(trimmed, in: options) {
      return .init(selection: match.id, customValue: "")
    }
    if let first = options.first, trimmed.isEmpty || !allowsCustom {
      return .init(selection: first.id, customValue: "", replacementValue: first.id)
    }
    if !allowsCustom {
      return .init(selection: "", customValue: "")
    }
    return .init(selection: ModelCatalog.customOptionID, customValue: trimmed)
  }

  /// The state after the bound value or the option list changes. Several
  /// pickers can share one setting, so a value chosen elsewhere is reflected
  /// rather than overwritten; it is replaced only when `repairsInvalidValue`
  /// is set and the picker has no Custom… entry to show it in.
  static func synced(
    with value: String,
    options: [ModelCatalog.Option],
    allowsCustom: Bool,
    repairsInvalidValue: Bool
  ) -> ModelPickerSelection {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = match(trimmed, in: options) {
      return .init(selection: match.id, customValue: "")
    }
    if allowsCustom {
      return .init(selection: ModelCatalog.customOptionID, customValue: trimmed)
    }
    if repairsInvalidValue, let first = options.first {
      return .init(selection: first.id, customValue: "", replacementValue: first.id)
    }
    return .init(selection: "", customValue: "")
  }

  private static func match(_ trimmed: String, in options: [ModelCatalog.Option]) -> ModelCatalog.Option? {
    options.first { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }
  }
}
