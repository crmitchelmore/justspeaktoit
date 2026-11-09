import SpeakCore
import SwiftUI

struct VoicePicker: View {
  let voices: [TTSVoice]
  let storedAPIKeyIdentifiers: [String]
  @Binding var selection: String
  var preview: ((String) -> Void)?
  var previewDisabled = false

  @State private var showsChooser = false

  var body: some View {
    Button {
      showsChooser = true
    } label: {
      HStack {
        Text(voices.first { $0.id == selection }?.displayName ?? selection)
        Spacer()
        ModelCredentialStatusView(availability: availability(for: selection))
        Image(systemName: "chevron.up.chevron.down")
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
    .accessibilityLabel("Voice")
    .accessibilityValue(voices.first { $0.id == selection }?.displayName ?? selection)
    .sheet(isPresented: $showsChooser) {
      VoiceChooserSheet(
        voices: voices,
        storedAPIKeyIdentifiers: storedAPIKeyIdentifiers,
        selection: $selection,
        preview: preview,
        previewDisabled: previewDisabled
      )
    }
  }

  private func availability(for voiceID: String) -> ModelCredentialAvailability {
    ModelCredentialResolver.availability(
      for: voiceID, purpose: .voiceOutput, storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
    )
  }
}

private struct VoiceChooserSheet: View {
  let voices: [TTSVoice]
  let storedAPIKeyIdentifiers: [String]
  @Binding var selection: String
  let preview: ((String) -> Void)?
  let previewDisabled: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var filter = VoiceChooserFilter()

  private var providers: [VoiceChooserFilter.Group] {
    VoiceChooserFilter().groups(in: voices, selection: "", availability: availability)
  }

  private var groups: [VoiceChooserFilter.Group] {
    filter.groups(in: voices, selection: selection, availability: availability)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Choose Voice")
          .font(.headline)
        Spacer()
        Button("Done") { dismiss() }
      }
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

      List {
        if let current = filter.pinnedVoice(in: voices, selection: selection) {
          Section("Current voice") {
            voiceRow(current)
          }
        }
        if groups.isEmpty {
          ContentUnavailableView {
            Label("No matching voices", systemImage: "magnifyingglass")
          } description: {
            Text("Try a different search or clear your filters.")
          } actions: {
            Button("Clear filters") { filter = VoiceChooserFilter() }
          }
        }
        ForEach(groups) { group in
          Section("\(group.provider.displayName) (\(group.voices.count))") {
            ForEach(group.voices) { voice in
              voiceRow(voice)
            }
          }
        }
      }
      .searchable(text: $filter.query, prompt: "Search voices, providers or traits")
    }
    .padding(16)
    .frame(minWidth: 780, minHeight: 520)
    .onAppear {
      filter.usableOnly = voices.contains { VoiceChooserFilter.isUsable(availability($0)) }
    }
  }

  private func voiceRow(_ voice: TTSVoice) -> some View {
    HStack(spacing: 10) {
      Button {
        selection = voice.id
        dismiss()
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(voice.name)
              .font(.body)
            Text(voice.provider.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
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
          if voice.id == selection {
            Image(systemName: "checkmark")
              .accessibilityLabel("Selected")
          }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
      }
      .buttonStyle(.plain)
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
  }

  private func availability(_ voice: TTSVoice) -> ModelCredentialAvailability {
    ModelCredentialResolver.availability(
      for: voice.id, purpose: .voiceOutput, storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
    )
  }
}
