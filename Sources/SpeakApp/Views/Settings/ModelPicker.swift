import SpeakCore
import SwiftUI

/// Builds the live OpenRouter browser a picker's OpenRouter entry opens: it is
/// given a closure that applies a choice and one that returns to the native list.
typealias ModelPickerOpenRouterBrowser = (
  _ select: @escaping (String) -> Void, _ back: @escaping () -> Void
) -> AnyView

struct ModelPicker: View {
  let title: String
  let help: String?
  let options: [ModelCatalog.Option]
  let credentialPurpose: ModelCredentialPurpose
  let storedAPIKeyIdentifiers: Set<String>
  let usesDetailedChooser: Bool
  let allowsCustom: Bool
  let openRouterBrowser: ModelPickerOpenRouterBrowser?
  @Binding var value: String

  @State var selection: String
  @State private var customValue: String
  @State private var isShowingChooser: Bool = false

  init(
    title: String,
    help: String? = nil,
    options: [ModelCatalog.Option],
    value: Binding<String>,
    credentialPurpose: ModelCredentialPurpose,
    storedAPIKeyIdentifiers: Set<String>,
    usesDetailedChooser: Bool = false,
    allowsCustom: Bool = true,
    openRouterBrowser: ModelPickerOpenRouterBrowser? = nil
  ) {
    self.title = title
    self.help = help
    self.options = options
    self.credentialPurpose = credentialPurpose
    self.storedAPIKeyIdentifiers = storedAPIKeyIdentifiers
    self.usesDetailedChooser = usesDetailedChooser
    self.allowsCustom = allowsCustom
    self.openRouterBrowser = openRouterBrowser
    _value = value

    let initial = ModelPickerSelection.initial(
      for: value.wrappedValue, options: options, allowsCustom: allowsCustom
    )
    _selection = State(initialValue: initial.selection)
    _customValue = State(initialValue: initial.customValue)
    if let replacement = initial.replacementValue {
      Self.repair(value, from: value.wrappedValue, to: replacement)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if usesDetailedChooser || openRouterBrowser != nil || LongListPickerPolicy.usesSheet(count: options.count) {
        Button {
          isShowingChooser = true
        } label: {
          HStack {
            Text(selectedOption.map(selectionLabel) ?? (customValue.isEmpty ? "Custom…" : customValue))
            Spacer()
            ModelCredentialStatusView(availability: selectedCredentialAvailability)
            if let option = selectedOption {
              ModelPricingBadges(option: option, compact: true)
              ModelTagBadges(tags: option.tags, compact: true)
              LatencyBadgeCompact(option: option)
            }
            Image(systemName: "chevron.up.chevron.down")
              .imageScale(.small)
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
        .settingsControlChrome()
        .speakTooltip(tooltipText)
        .accessibilityLabel(title)
        .accessibilityValue(selectedDisplayName)
        .accessibilityIdentifier("modelPicker.\(Self.accessibilityIdentifierComponent(for: title))")
        .accessibilityAddTraits(.isButton)
        .sheet(isPresented: $isShowingChooser) {
          ModelChooserSheet(
            title: title,
            options: options,
            credentialPurpose: credentialPurpose,
            storedAPIKeyIdentifiers: storedAPIKeyIdentifiers,
            allowsCustom: allowsCustom,
            openRouterBrowser: openRouterBrowser,
            selection: $selection
          )
        }
      } else {
        Picker(title, selection: $selection) {
          let groups = ModelPickerGrouping.groups(options, purpose: credentialPurpose)
          if groups.direct.isEmpty || groups.openRouter.isEmpty {
            menuRows(groups.direct + groups.openRouter)
          } else {
            // Native routes first; OpenRouter routes in their own labelled group.
            menuRows(groups.direct)
            Section(ModelPickerGrouping.openRouterTitle) {
              menuRows(groups.openRouter)
            }
          }
          if allowsCustom {
            HStack {
              Text("Custom…")
              Spacer()
              ModelCredentialStatusView(
                availability: credentialAvailability(for: ModelCatalog.customOptionID)
              )
            }
            .accessibilityElement(children: .combine)
            .tag(ModelCatalog.customOptionID)
          }
        }
        .settingsMenuPicker()
        .speakTooltip(tooltipText)
      }

      if let help {
        Text(help)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let option = selectedOption {
        HStack(spacing: 8) {
          if let description = option.description {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          ModelPricingBadges(option: option, compact: false)
          ModelTagBadges(tags: option.tags, compact: false)
          LatencyBadge(option: option)
        }
      }

      if selection == ModelCatalog.customOptionID {
        TextField("Custom model identifier", text: $customValue, prompt: Text("provider/model"))
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .speakTooltip(
            "Type the exact provider/model identifier from your transcription service, such as openai/whisper-1."
          )
      } else {
        HStack(spacing: 6) {
          Image(systemName: "info.circle")
            .imageScale(.small)
            .foregroundStyle(.secondary)
          Text(ModelCatalog.friendlyName(for: value))
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          ModelCredentialStatusView(availability: selectedCredentialAvailability, showsText: true)
        }
      }
    }
    .onChange(of: selection) { _, newValue in
      // Only a user choice writes through. Selections that merely mirror the
      // bound value, or show that it is not one of these options, must not.
      let mirroredValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if newValue.isEmpty || newValue.caseInsensitiveCompare(mirroredValue) == .orderedSame {
        return
      }
      if newValue == ModelCatalog.customOptionID {
        if customValue.isEmpty {
          customValue = value
        }
        value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        value = newValue
      }
    }
    .onChange(of: customValue) { _, newValue in
      if selection == ModelCatalog.customOptionID {
        value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    .onChange(of: value) { _, newValue in
      // Several pickers can share one setting (Apple and remote live models),
      // so a value chosen elsewhere is reflected, never overwritten.
      syncSelection(with: newValue, repairsInvalidValue: false)
    }
    .onChange(of: options.map(\.id)) { _, _ in
      syncSelection(with: value, repairsInvalidValue: true)
    }
  }

  /// Replaces an invalid value on the next turn unless something else has
  /// changed it in the meantime.
  private static func repair(_ value: Binding<String>, from invalidValue: String, to replacement: String) {
    DispatchQueue.main.async {
      guard value.wrappedValue == invalidValue else { return }
      value.wrappedValue = replacement
    }
  }

  private var selectedOption: ModelCatalog.Option? {
    options.first { option in
      option.id.caseInsensitiveCompare(selection) == .orderedSame
    }
  }

  /// The label VoiceOver reads as the picker's current value.
  private func menuRows(_ rows: [ModelCatalog.Option]) -> some View {
    ForEach(rows) { option in
      HStack {
        Text(option.displayName)
        Spacer()
        ModelCredentialStatusView(availability: credentialAvailability(for: option.id))
      }
      .accessibilityElement(children: .combine)
      .tag(option.id)
    }
  }

  private var selectedDisplayName: String {
    selectedOption.map(selectionLabel) ?? (customValue.isEmpty ? "Custom" : customValue)
  }

  /// "OpenRouter › Model" for OpenRouter routes, so the route is never ambiguous.
  private func selectionLabel(_ option: ModelCatalog.Option) -> String {
    ModelPickerGrouping.selectionLabel(
      for: option.id, displayName: option.displayName, purpose: credentialPurpose
    )
  }

  /// Stable, UI-test friendly component derived from the picker's title,
  /// e.g. "Post-processing model" -> "postProcessingModel".
  static func accessibilityIdentifierComponent(for title: String) -> String {
    let words = title
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    guard let first = words.first else { return "model" }
    return ([first.prefix(1).lowercased() + first.dropFirst()]
      + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() })
      .joined()
  }

  private var selectedCredentialAvailability: ModelCredentialAvailability {
    credentialAvailability(for: selection == ModelCatalog.customOptionID ? customValue : selection)
  }

  private func credentialAvailability(for modelIdentifier: String) -> ModelCredentialAvailability {
    ModelCredentialResolver.availability(
      for: modelIdentifier.isEmpty ? ModelCatalog.customOptionID : modelIdentifier,
      purpose: credentialPurpose,
      storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
    )
  }

  private var tooltipText: String {
    if let help, !help.isEmpty {
      return help
    }
    if let description = selectedOption?.description, !description.isEmpty {
      return description
    }
    return "Choose which model Speak should use for this step."
  }

  private func syncSelection(with newValue: String, repairsInvalidValue: Bool) {
    let synced = ModelPickerSelection.synced(
      with: newValue, options: options, allowsCustom: allowsCustom, repairsInvalidValue: repairsInvalidValue
    )
    if selection != synced.selection {
      selection = synced.selection
    }
    if customValue != synced.customValue {
      customValue = synced.customValue
    }
    if let replacement = synced.replacementValue, value != replacement {
      value = replacement
    }
  }
}
