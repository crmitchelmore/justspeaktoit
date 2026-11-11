import AppKit
import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

/// Edits the draft (or picks it from history) and starts synthesis.
struct VoiceOutputTextCard: View {
  @ObservedObject var composer: VoiceOutputComposer
  @EnvironmentObject private var tts: TextToSpeechManager
  @EnvironmentObject private var history: HistoryManager

  var body: some View {
    SpeakDensityCard(title: "Text", systemImage: "text.alignleft", tint: .orange) {
      VStack(alignment: .leading, spacing: 12) {
        if self.composer.inputSource == .history {
          self.historyItemPicker
        } else {
          TextEditor(text: self.$composer.inputText)
            .font(.body)
            .frame(minHeight: 300)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .onChange(of: self.composer.inputText) { _, _ in
              self.composer.updateEstimatedCost(using: self.tts)
            }
        }

        HStack {
          Text("\(self.composer.inputText.count) characters")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let cost = self.composer.estimatedCost, cost > 0 {
            Spacer()
            Text("Est. cost: $\(cost, format: .number.precision(.fractionLength(4)))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 12) {
          Button {
            Task {
              await self.composer.synthesize(with: self.tts)
            }
          } label: {
            Label("Synthesize", systemImage: "waveform.circle")
          }
          .buttonStyle(.borderedProminent)
          .disabled(self.composer.inputText.isEmpty || self.tts.isSynthesizing)

          if self.tts.isPlaying {
            Button("Stop") {
              self.tts.stop()
            }
            .buttonStyle(.bordered)
          }

          Button("Clear") {
            self.composer.inputText = ""
          }
          .buttonStyle(.bordered)
          .disabled(self.composer.inputText.isEmpty)
        }
      }
    }
  }

  private var historyItemPicker: some View {
    VStack(alignment: .leading, spacing: 12) {
      let items = self.history.items(matching: .none)
      if items.isEmpty {
        Text("No history items available")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 40)
      } else {
        List(selection: self.$composer.selectedHistoryItem) {
          ForEach(items) { item in
            let displayText = item.postProcessedTranscription ?? item.rawTranscription ?? ""
            VStack(alignment: .leading, spacing: 4) {
              Text(displayText.prefix(100))
                .lineLimit(2)
              Text(item.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(item as HistoryItem?)
          }
        }
        .frame(height: 300)
        .onChange(of: self.composer.selectedHistoryItem) { _, item in
          self.composer.useHistoryItem(item)
        }
      }
    }
  }
}

/// The last synthesis: its failure, or its details with play and export.
struct VoiceOutputResultCard: View {
  @EnvironmentObject private var tts: TextToSpeechManager

  var body: some View {
    SpeakDensityCard(title: "Result", systemImage: "checkmark.circle", tint: .green) {
      VStack(alignment: .leading, spacing: 12) {
        if let error = self.tts.lastError {
          self.failure(error)
        } else if let result = self.tts.lastResult {
          self.completed(result)
        }
      }
    }
  }

  private func failure(_ error: Error) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 4) {
        Text("Synthesis Failed")
          .font(.headline)
          .foregroundStyle(.red)
        Text(error.localizedDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.red.opacity(0.1))
    .cornerRadius(8)
  }

  private func completed(_ result: TTSResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text("Synthesis Complete")
          .font(.headline)
      }

      self.details(result)

      HStack(spacing: 8) {
        if self.tts.isPlaying {
          Button("Pause") {
            self.tts.pause()
          }
          .buttonStyle(.bordered)
        } else {
          Button("Play") {
            Task {
              try? await self.tts.play(url: result.audioURL)
            }
          }
          .buttonStyle(.bordered)
        }

        Button("Export…") {
          Self.exportAudio(result.audioURL)
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private func details(_ result: TTSResult) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
      GridRow {
        Text("Provider:")
          .foregroundStyle(.secondary)
        Text(result.provider.displayName)
      }
      GridRow {
        Text("Duration:")
          .foregroundStyle(.secondary)
        Text(
          String(format: "%.1f seconds", result.duration)
        )
      }
      GridRow {
        Text("Characters:")
          .foregroundStyle(.secondary)
        Text("\(result.characterCount)")
      }
      if let cost = result.cost {
        GridRow {
          Text("Cost:")
            .foregroundStyle(.secondary)
          Text("$\(cost, format: .number.precision(.fractionLength(4)))")
        }
      }
    }
    .font(.caption)
  }

  private static func exportAudio(_ url: URL) {
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [
      UTType(filenameExtension: url.pathExtension) ?? .audio
    ]
    savePanel.nameFieldStringValue = "voice_output.\(url.pathExtension)"

    savePanel.begin { response in
      guard response == .OK, let destinationURL = savePanel.url else { return }
      try? FileManager.default.copyItem(at: url, to: destinationURL)
    }
  }
}
