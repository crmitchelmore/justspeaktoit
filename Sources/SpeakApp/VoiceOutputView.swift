import SwiftUI
import UniformTypeIdentifiers

enum TTSInputSource: String, CaseIterable, Identifiable {
  case manual
  case clipboard
  case history
  case file

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .manual: return "Type Text"
    case .clipboard: return "From Clipboard"
    case .history: return "From History"
    case .file: return "Import File"
    }
  }

  var icon: String {
    switch self {
    case .manual: return "text.bubble"
    case .clipboard: return "doc.on.clipboard"
    case .history: return "clock.arrow.circlepath"
    case .file: return "doc.text"
    }
  }
}

struct VoiceOutputView: View {
  @EnvironmentObject private var tts: TextToSpeechManager
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var history: HistoryManager

  @State private var inputSource: TTSInputSource = .manual
  @State private var inputText: String = ""
  @State private var selectedVoice: String = ""
  @State private var selectedHistoryItem: HistoryItem?
  @State private var availableVoices: [TTSVoice] = []
  @State private var isImportingFile = false
  @State private var showingSSMLHelper = false
  @State private var estimatedCost: Decimal?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        heroHeader
        contentSections
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .background(
      LinearGradient(
        colors: [Color.green.opacity(0.08), Color(nsColor: .windowBackgroundColor)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    )
    .task {
      selectedVoice = settings.defaultTTSVoice
      await loadAvailableVoices()
    }
    .fileImporter(
      isPresented: $isImportingFile,
      allowedContentTypes: [.plainText, .text, .utf8PlainText],
      allowsMultipleSelection: false
    ) { result in
      handleFileImport(result)
    }
    .sheet(isPresented: $showingSSMLHelper) {
      SSMLHelperView(text: $inputText)
    }
  }

  private var heroHeader: some View {
    VStack(alignment: .leading, spacing: 18) {
      heroTitleRow
      heroStatsRow
    }
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color.green, Color.mint.opacity(0.8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(32)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1)
    )
    .shadow(color: Color.green.opacity(0.3), radius: 24, x: 0, y: 16)
  }

  private var heroTitleRow: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Voice Output")
          .font(.largeTitle.bold())
          .foregroundStyle(.white)
        Text("Convert text to natural speech with multiple providers and advanced controls.")
          .font(.headline)
          .foregroundStyle(.white.opacity(0.85))
      }
      Spacer()
      heroActionButton
    }
  }

  @ViewBuilder
  private var heroActionButton: some View {
    if tts.isSynthesizing {
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)
        Text("Synthesizing...")
          .font(.headline)
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 18)
      .background(Capsule().fill(Color.white.opacity(0.2)))
      .foregroundStyle(Color.white)
    } else if tts.isPlaying {
      Button("Stop") {
        tts.stop()
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 18)
      .background(Capsule().fill(Color.white.opacity(0.15)))
      .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
      .foregroundStyle(Color.white)
      .buttonStyle(.plain)
    }
  }

  @ViewBuilder
  private var heroStatsRow: some View {
    let costString = estimatedCost.map { String(format: "$%.4f", NSDecimalNumber(decimal: $0).doubleValue) }
    let durationString = tts.lastResult.map { String(format: "%.1fs", $0.duration) }

    HStack(spacing: 16) {
      heroChip(title: "Characters", value: "\(inputText.count)", systemImage: "textformat.abc")
      if let cost = estimatedCost, cost > 0, let formatted = costString {
        heroChip(title: "Est. Cost", value: formatted, systemImage: "dollarsign.circle")
      }
      if let _ = tts.lastResult, let formatted = durationString {
        heroChip(title: "Last Duration", value: formatted, systemImage: "waveform")
      }
    }
  }

  private func heroChip(title: String, value: String, systemImage: String) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: systemImage)
        .imageScale(.large)
        .foregroundStyle(.white.opacity(0.85))
      VStack(alignment: .leading, spacing: 4) {
        Text(title.uppercased())
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.7))
        Text(value)
          .font(.title3.bold())
          .foregroundStyle(.white)
      }
      Spacer()
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.white.opacity(0.12))
    )
  }

  private var contentSections: some View {
    LazyVStack(spacing: 24) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24)], spacing: 24) {
        inputSourceCard
        voiceSelectionCard
      }

      synthesisControlsCard
      textWorkspaceCard

      if tts.lastResult != nil || tts.lastError != nil {
        resultCard
      }
    }
  }

  private var inputSourceCard: some View {
    SettingsCard(title: "Input Source", systemImage: "arrow.down.doc", tint: .brandLagoon) {
      VStack(alignment: .leading, spacing: 12) {
        ViewThatFits(in: .horizontal) {
          Picker("Source", selection: $inputSource) {
            ForEach(TTSInputSource.allCases) { source in
              Label(source.displayName, systemImage: source.icon).tag(source)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: .infinity)

          Picker("Source", selection: $inputSource) {
            ForEach(TTSInputSource.allCases) { source in
              Label(source.displayName, systemImage: source.icon).tag(source)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: inputSource) { _, newValue in
          handleInputSourceChange(newValue)
        }

        if inputSource == .clipboard {
          Button("Load from Clipboard") {
            loadFromClipboard()
          }
          .buttonStyle(.bordered)
        } else if inputSource == .file {
          Button("Choose File...") {
            isImportingFile = true
          }
          .buttonStyle(.bordered)
        }
      }
    }
  }

  private var voiceSelectionCard: some View {
    SettingsCard(title: "Voice", systemImage: "person.wave.2", tint: .brandAccent) {
      VStack(alignment: .leading, spacing: 12) {
        if availableVoices.isEmpty {
          HStack {
            ProgressView()
              .scaleEffect(0.7)
            Text("Loading voices...")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          Picker("Voice", selection: $selectedVoice) {
            ForEach(availableVoices) { voice in
              Text(voice.displayName).tag(voice.id)
            }
          }
          .labelsHidden()

          if let voice = VoiceCatalog.voice(forID: selectedVoice) {
            HStack(spacing: 6) {
              ForEach(voice.traits.prefix(3), id: \.self) { trait in
                Text(trait.rawValue.capitalized)
                  .font(.caption2)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(Capsule().fill(Color.secondary.opacity(0.15)))
              }
            }
          }

          Button {
            Task {
              await tts.previewVoice(selectedVoice)
            }
          } label: {
            Label("Preview Voice", systemImage: "play.circle")
          }
          .buttonStyle(.bordered)
          .disabled(tts.isSynthesizing)
        }
      }
    }
  }

  private var synthesisControlsCard: some View {
    SettingsCard(title: "Controls", systemImage: "slider.horizontal.3", tint: .green) {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Speed")
              .font(.subheadline)
            Spacer()
            Text(String(format: "%.2fx", settings.ttsSpeed))
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Slider(value: $settings.ttsSpeed, in: 0.5...2.0, step: 0.1)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Pitch")
              .font(.subheadline)
            Spacer()
            Text("\(settings.ttsPitch > 0 ? "+" : "")\(Int(settings.ttsPitch)) st")
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Slider(value: $settings.ttsPitch, in: -12...12, step: 1)
        }

        Divider()

        Toggle("Use SSML", isOn: $settings.ttsUseSSML)
          .help("Enable SSML for advanced voice control")

        if settings.ttsUseSSML {
          Button("SSML Helper") {
            showingSSMLHelper = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        Toggle("Auto-play", isOn: $settings.ttsAutoPlay)
        Toggle("Save to recordings", isOn: $settings.ttsSaveToDirectory)
      }
    }
  }

  private var textWorkspaceCard: some View {
    SettingsCard(title: "Text", systemImage: "text.alignleft", tint: .orange) {
      VStack(alignment: .leading, spacing: 12) {
        if inputSource == .history {
          historyItemPicker
        } else {
          TextEditor(text: $inputText)
            .font(.body)
            .frame(minHeight: 300)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .onChange(of: inputText) { _, newValue in
              updateEstimatedCost()
            }
        }

        HStack {
          Text("\(inputText.count) characters")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let cost = estimatedCost, cost > 0 {
            Spacer()
            Text("Est. cost: $\(cost, format: .number.precision(.fractionLength(4)))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 12) {
          Button {
            Task {
              await synthesize()
            }
          } label: {
            Label("Synthesize", systemImage: "waveform.circle")
          }
          .buttonStyle(.borderedProminent)
          .disabled(inputText.isEmpty || tts.isSynthesizing)

          if tts.isPlaying {
            Button("Stop") {
              tts.stop()
            }
            .buttonStyle(.bordered)
          }

          Button("Clear") {
            inputText = ""
          }
          .buttonStyle(.bordered)
          .disabled(inputText.isEmpty)
        }
      }
    }
  }

  private var historyItemPicker: some View {
    VStack(alignment: .leading, spacing: 12) {
      let items = history.items(matching: .none)
      if items.isEmpty {
        Text("No history items available")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 40)
      } else {
        List(selection: $selectedHistoryItem) {
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
        .onChange(of: selectedHistoryItem) { _, item in
          if let item {
            inputText = item.postProcessedTranscription ?? item.rawTranscription ?? ""
          }
        }
      }
    }
  }

  private var resultCard: some View {
    SettingsCard(title: "Result", systemImage: "checkmark.circle", tint: .green) {
      VStack(alignment: .leading, spacing: 12) {
        if let error = tts.lastError {
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
        } else if let result = tts.lastResult {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("Synthesis Complete")
                .font(.headline)
            }

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

            HStack(spacing: 8) {
              if tts.isPlaying {
                Button("Pause") {
                  tts.pause()
                }
                .buttonStyle(.bordered)
              } else {
                Button("Play") {
                  Task {
                    try? await tts.play(url: result.audioURL)
                  }
                }
                .buttonStyle(.bordered)
              }

              Button("Export...") {
                exportAudio(result.audioURL)
              }
              .buttonStyle(.bordered)
            }
          }
        }
      }
    }
  }

  // MARK: - Helper Functions

  private func loadAvailableVoices() async {
    availableVoices = await tts.availableVoices()
    if selectedVoice.isEmpty || !availableVoices.contains(where: { $0.id == selectedVoice }) {
      selectedVoice = settings.defaultTTSVoice
    }
  }

  private func handleInputSourceChange(_ source: TTSInputSource) {
    switch source {
    case .clipboard:
      loadFromClipboard()
    case .history:
      break
    case .manual, .file:
      break
    }
  }

  private func loadFromClipboard() {
    if let string = NSPasteboard.general.string(forType: .string) {
      inputText = string
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      do {
        inputText = try String(contentsOf: url, encoding: .utf8)
      } catch {
        print("Failed to read file: \(error)")
      }
    case .failure(let error):
      print("File import failed: \(error)")
    }
  }

  private func updateEstimatedCost() {
    estimatedCost = tts.estimatedCost(text: inputText, voice: selectedVoice)
  }

  private func synthesize() async {
    do {
      _ = try await tts.synthesize(text: inputText, voice: selectedVoice, useSSML: nil)
    } catch {
      print("Synthesis error: \(error)")
    }
  }

  private func exportAudio(_ url: URL) {
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

// MARK: - SSML Helper View

struct SSMLHelperView: View {
  @Binding var text: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("SSML Helper")
        .font(.title2.bold())

      Text(
        "Wrap your text with SSML tags for advanced control. Common tags:"
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ssmlExample("<speak>Your text here</speak>", description: "Root tag (required)")
          ssmlExample("<break time='500ms'/>", description: "Pause for duration")
          ssmlExample("<emphasis level='strong'>text</emphasis>", description: "Emphasize text")
          ssmlExample(
            "<prosody rate='slow' pitch='+2st'>text</prosody>",
            description: "Control rate and pitch"
          )
          ssmlExample("<say-as interpret-as='digits'>123</say-as>", description: "Number format")
          ssmlExample(
            "<phoneme alphabet='ipa' ph='təˈmeɪtoʊ'>tomato</phoneme>",
            description: "Pronunciation"
          )
        }
      }
      .frame(height: 200)

      HStack {
        Button("Close") {
          dismiss()
        }
        .buttonStyle(.bordered)

        Spacer()

        Button("Wrap with <speak>") {
          if !text.contains("<speak>") {
            text = "<speak>\(text)</speak>"
          }
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 500)
  }

  private func ssmlExample(_ tag: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(tag)
        .font(.system(.caption, design: .monospaced))
        .padding(6)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(4)

      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()

      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tag, forType: .string)
      }
      .buttonStyle(.borderless)
      .controlSize(.mini)
    }
  }
}

// MARK: - Settings Card (reused from SettingsView pattern)

private struct SettingsCard<Content: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tint.opacity(0.15))
            .frame(width: 44, height: 44)
          Image(systemName: systemImage)
            .foregroundStyle(tint)
            .font(.system(size: 20, weight: .semibold))
        }
        Text(title)
          .font(.headline)
        Spacer(minLength: 0)
      }
      content
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(tint.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: tint.opacity(0.08), radius: 18, x: 0, y: 12)
  }
}
