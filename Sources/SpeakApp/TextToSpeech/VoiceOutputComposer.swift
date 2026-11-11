import AppKit
import SpeakCore
import SwiftUI
import os.log

private let logger = SpeakLogger.logger(category: "VoiceOutput")

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

/// Owns the Voice Output page's draft: where the text comes from, the text
/// itself, the chosen voice and the cost estimate for speaking it.
@MainActor
final class VoiceOutputComposer: ObservableObject {
  @Published var inputSource: TTSInputSource = .manual
  @Published var inputText: String = ""
  @Published var selectedVoice: String = ""
  @Published var selectedHistoryItem: HistoryItem?
  @Published var isImportingFile = false
  @Published var showingSSMLHelper = false
  @Published private(set) var availableVoices: [TTSVoice] = []
  @Published private(set) var estimatedCost: Decimal?

  func loadAvailableVoices(from tts: TextToSpeechManager, defaultVoice: String) async {
    self.availableVoices = await tts.availableVoices()
    if self.selectedVoice.isEmpty {
      self.selectedVoice = defaultVoice
    }
  }

  func inputSourceChanged(to source: TTSInputSource) {
    if source == .clipboard {
      self.loadFromClipboard()
    }
  }

  func loadFromClipboard() {
    if let string = NSPasteboard.general.string(forType: .string) {
      self.inputText = string
    }
  }

  func useHistoryItem(_ item: HistoryItem?) {
    if let item {
      self.inputText = item.postProcessedTranscription ?? item.rawTranscription ?? ""
    }
  }

  func readImportedFile(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      do {
        self.inputText = try String(contentsOf: url, encoding: .utf8)
      } catch {
        // Redacted: the read error carries the imported file's name and path.
        logger.error("Failed to read file: \(error.localizedDescription, privacy: .private)")
      }
    case .failure(let error):
      logger.error("File import failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func updateEstimatedCost(using tts: TextToSpeechManager) {
    self.estimatedCost = tts.estimatedCost(text: self.inputText, voice: self.selectedVoice)
  }

  func synthesize(with tts: TextToSpeechManager) async {
    do {
      _ = try await tts.synthesize(text: self.inputText, voice: self.selectedVoice, useSSML: nil)
    } catch {
      logger.error("Synthesis error: \(error.localizedDescription, privacy: .public)")
    }
  }
}
