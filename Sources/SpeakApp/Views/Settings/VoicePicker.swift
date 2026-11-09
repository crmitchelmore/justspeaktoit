import SpeakCore
import SwiftUI

struct VoicePicker: View {
  let voices: [TTSVoice]
  let storedAPIKeyIdentifiers: [String]
  @Binding var selection: String
  var preview: ((String) -> Void)?
  var previewDisabled = false

  @State private var filter = VoiceChooserFilter()

  private var providers: [VoiceChooserFilter.Group] {
    VoiceChooserFilter().groups(in: voices, selection: "", availability: availability)
  }

  private var includedIDs: Set<String> {
    Set(filter.groups(in: voices, selection: "", availability: availability).flatMap { $0.voices.map(\.id) })
  }

  var body: some View {
    let included = includedIDs
    LongListPicker(
      title: "Voice", items: VoiceChooserFilter.sortedVoices(voices), id: { $0.id }, selection: $selection,
      searchText: { [$0.name, $0.provider.displayName] + $0.traits.map(\.rawValue) },
      group: { $0.provider.displayName }, alwaysUsesSheet: true,
      includes: { included.contains($0.id) },
      controls: { AnyView(filters) },
      clearFilters: { filter = VoiceChooserFilter() },
      onOpen: { filter.usableOnly = voices.contains { VoiceChooserFilter.isUsable(availability($0)) } },
      selectedLabel: { voice in
        AnyView(HStack {
          Text(voice.displayName)
          Spacer()
          ModelCredentialStatusView(availability: availability(voice))
        })
      },
      accessory: { voice in AnyView(previewButton(voice)) }
    ) { voice in
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(voice.name).font(.body)
          Text(voice.provider.displayName).font(.caption).foregroundStyle(.secondary)
          HStack(spacing: 6) {
            ForEach(voice.traits.prefix(3), id: \.self) { trait in
              Text(trait.rawValue.capitalized)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
          }
        }
        Spacer()
        ModelCredentialStatusView(availability: availability(voice))
      }
    }
    .accessibilityValue(voices.first { $0.id == selection }?.displayName ?? selection)
  }

  private var filters: some View {
    VStack(spacing: 12) {
      HStack {
        Picker("Provider", selection: $filter.provider) {
          Text("All providers (\(voices.count))").tag(TTSProvider?.none)
          ForEach(providers) { group in
            Text("\(group.provider.displayName) (\(group.voices.count))")
              .tag(TTSProvider?.some(group.provider))
          }
        }
        .pickerStyle(.menu)
        Toggle("Only show voices I can use", isOn: $filter.usableOnly)
      }
      Picker("Gender", selection: $filter.gender) {
        ForEach(VoiceChooserFilter.Gender.allCases, id: \.self) { gender in
          Text(gender.rawValue.capitalized).tag(gender)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  @ViewBuilder
  private func previewButton(_ voice: TTSVoice) -> some View {
    if let preview {
      Button {
        preview(voice.id)
      } label: {
        Image(systemName: "play.circle")
      }
      .buttonStyle(.borderless)
      .disabled(previewDisabled)
      .accessibilityLabel("Preview \(voice.displayName)")
    }
  }

  private func availability(_ voice: TTSVoice) -> ModelCredentialAvailability {
    ModelCredentialResolver.availability(
      for: voice.id, purpose: .voiceOutput, storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
    )
  }
}
