// swiftlint:disable file_length
import SpeakCore
import SwiftUI

// swiftlint:disable:next type_body_length
struct ModelPicker: View {
  let title: String
  let help: String?
  let options: [ModelCatalog.Option]
  let credentialPurpose: ModelCredentialPurpose
  let storedAPIKeyIdentifiers: Set<String>
  let usesDetailedChooser: Bool
  let allowsCustom: Bool
  @Binding var value: String

  private struct ModelTagBadges: View {
    let tags: [ModelCatalog.Tag]
    let compact: Bool

    var body: some View {
      if tags.isEmpty {
        EmptyView()
      } else {
        HStack(spacing: 6) {
          ForEach(tags.prefix(compact ? 2 : tags.count), id: \.self) { tag in
            Text(tag.displayName)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(tagForegroundColor(tag))
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(
                Capsule(style: .continuous)
                  .fill(tagBackgroundColor(tag))
              )
          }
        }
      }
    }

    private func tagBackgroundColor(_ tag: ModelCatalog.Tag) -> Color {
      switch tag {
      case .fast: return Color.brandLagoon.opacity(0.12)
      case .cheap: return Color.green.opacity(0.14)
      case .quality: return Color.brandAccent.opacity(0.12)
      case .leading: return Color.brandAccentWarm.opacity(0.14)
      case .privacy: return Color.brandLagoon.opacity(0.14)
      }
    }

    private func tagForegroundColor(_ tag: ModelCatalog.Tag) -> Color {
      switch tag {
      case .fast: return .brandLagoon
      case .cheap: return .green
      case .quality: return .brandAccent
      case .leading: return .brandAccentWarm
      case .privacy: return .brandLagoon
      }
    }
  }

  private struct ModelPricingBadges: View {
    let option: ModelCatalog.Option
    let compact: Bool

    var body: some View {
      if let pricing = option.pricing {
        HStack(spacing: 8) {
          if !compact, let contextLength = option.contextLength {
            Text(formatContext(contextLength))
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Text(pricing.compactDisplay)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }

    private func formatContext(_ contextLength: Int) -> String {
      if contextLength >= 1_000_000 {
        return "\(Int(Double(contextLength) / 1_000_000.0))M ctx"
      }
      return "\(Int(Double(contextLength) / 1_000.0))k ctx"
    }
  }

  private struct ModelChooserSheet: View {
    let title: String
    let options: [ModelCatalog.Option]
    let credentialPurpose: ModelCredentialPurpose
    let storedAPIKeyIdentifiers: Set<String>
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selectedTag: ModelCatalog.Tag? = nil

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(title)
            .font(.headline)
          Spacer()
          Button("Done") { dismiss() }
        }

        Picker("Filter", selection: $selectedTag) {
          Text("All").tag(ModelCatalog.Tag?.none)
          ForEach(ModelCatalog.Tag.allCases, id: \.self) { tag in
            Text(tag.displayName).tag(ModelCatalog.Tag?.some(tag))
          }
        }
        .pickerStyle(.segmented)

        List {
          ForEach(filteredOptions) { option in
            Button {
              selection = option.id
              dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                  Text(option.displayName)
                    .font(.body)
                  Spacer()
                  if let contextLength = option.contextLength {
                    Text(formatContext(contextLength))
                      .font(.caption.monospacedDigit())
                      .foregroundStyle(.secondary)
                  }
                  if let pricing = option.pricing {
                    Text(pricing.compactDisplay)
                      .font(.caption.monospacedDigit())
                      .foregroundStyle(.secondary)
                  }
                  ModelCredentialStatusView(
                    availability: ModelCredentialResolver.availability(
                      for: option.id,
                      purpose: credentialPurpose,
                      storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
                    )
                  )
                  ModelTagBadges(tags: option.tags, compact: true)
                  LatencyBadgeCompact(option: option)
                }

                if let description = option.description, !description.isEmpty {
                  Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
          }

          Divider()

          Button {
            selection = ModelCatalog.customOptionID
            dismiss()
          } label: {
            HStack {
              Text("Custom…")
              Spacer()
              ModelCredentialStatusView(
                availability: ModelCredentialResolver.availability(
                  for: ModelCatalog.customOptionID,
                  purpose: credentialPurpose,
                  storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
                )
              )
            }
          }
          .buttonStyle(.plain)
        }
        .searchable(text: $query)
      }
      .padding(16)
      .frame(minWidth: 780, minHeight: 520)
    }

    private var filteredOptions: [ModelCatalog.Option] {
      var result = options
      if let selectedTag {
        result = result.filter { $0.tags.contains(selectedTag) }
      }
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        let lowered = trimmed.lowercased()
        result = result.filter {
          $0.displayName.lowercased().contains(lowered)
            || $0.id.lowercased().contains(lowered)
            || ($0.description?.lowercased().contains(lowered) ?? false)
        }
      }
      result.sort { lhs, rhs in
        let lhsLeading = lhs.tags.contains(.leading)
        let rhsLeading = rhs.tags.contains(.leading)
        if lhsLeading != rhsLeading { return lhsLeading && !rhsLeading }
        let lhsCheap = lhs.tags.contains(.cheap)
        let rhsCheap = rhs.tags.contains(.cheap)
        if lhsCheap != rhsCheap { return lhsCheap && !rhsCheap }
        let lhsFast = lhs.tags.contains(.fast)
        let rhsFast = rhs.tags.contains(.fast)
        if lhsFast != rhsFast { return lhsFast && !rhsFast }
        return lhs.displayName < rhs.displayName
      }
      return result
    }

    private func formatContext(_ contextLength: Int) -> String {
      if contextLength >= 1_000_000 {
        return "\(Int(Double(contextLength) / 1_000_000.0))M ctx"
      }
      return "\(Int(Double(contextLength) / 1_000.0))k ctx"
    }
  }

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
    allowsCustom: Bool = true
  ) {
    self.title = title
    self.help = help
    self.options = options
    self.credentialPurpose = credentialPurpose
    self.storedAPIKeyIdentifiers = storedAPIKeyIdentifiers
    self.usesDetailedChooser = usesDetailedChooser
    self.allowsCustom = allowsCustom
    _value = value

    let trimmed = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = options.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      _selection = State(initialValue: match.id)
      _customValue = State(initialValue: "")
    } else if trimmed.isEmpty, let first = options.first {
      _selection = State(initialValue: first.id)
      _customValue = State(initialValue: "")
      DispatchQueue.main.async {
        value.wrappedValue = first.id
      }
    } else if !allowsCustom, let first = options.first {
      _selection = State(initialValue: first.id)
      _customValue = State(initialValue: "")
      DispatchQueue.main.async {
        value.wrappedValue = first.id
      }
    } else if !allowsCustom {
      _selection = State(initialValue: "")
      _customValue = State(initialValue: "")
    } else {
      _selection = State(initialValue: ModelCatalog.customOptionID)
      _customValue = State(initialValue: trimmed)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if usesDetailedChooser {
        Button {
          isShowingChooser = true
        } label: {
          HStack {
            Text(selectedOption?.displayName ?? (customValue.isEmpty ? "Custom…" : customValue))
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
        .sheet(isPresented: $isShowingChooser) {
          ModelChooserSheet(
            title: title,
            options: options,
            credentialPurpose: credentialPurpose,
            storedAPIKeyIdentifiers: storedAPIKeyIdentifiers,
            selection: $selection
          )
        }
      } else {
        Picker(title, selection: $selection) {
          ForEach(options) { option in
            HStack {
              Text(option.displayName)
              Spacer()
              ModelCredentialStatusView(availability: credentialAvailability(for: option.id))
            }
            .accessibilityElement(children: .combine)
            .tag(option.id)
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
      syncSelection(with: newValue)
    }
    .onChange(of: options.map(\.id)) { _, _ in
      syncSelection(with: value)
    }
  }

  private var selectedOption: ModelCatalog.Option? {
    options.first { option in
      option.id.caseInsensitiveCompare(selection) == .orderedSame
    }
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

  // swiftlint:disable:next cyclomatic_complexity
  private func syncSelection(with newValue: String) {
    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = options.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      if selection != match.id {
        selection = match.id
      }
      if !customValue.isEmpty {
        customValue = ""
      }
    } else if allowsCustom {
      if selection != ModelCatalog.customOptionID {
        selection = ModelCatalog.customOptionID
      }
      if customValue != trimmed {
        customValue = trimmed
      }
    } else if let first = options.first {
      if selection != first.id {
        selection = first.id
      }
      if !customValue.isEmpty {
        customValue = ""
      }
      if value != first.id {
        value = first.id
      }
    } else {
      if !selection.isEmpty {
        selection = ""
      }
      if !customValue.isEmpty {
        customValue = ""
      }
    }
  }
}
