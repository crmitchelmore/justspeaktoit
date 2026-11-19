import SpeakCore
import Foundation

/// The capture side of a dictation session: what decides whether and how the
/// microphone opens. Passed whole to the start pipeline, the key-press primer
/// and capture warming.
struct SessionCaptureServices {
  let permissions: PermissionsManager
  let devices: AudioInputDeviceManager
  let hotKeys: HotKeyManager
  let audioFiles: AudioFileManager
  let profiles: DictationProfileStore
}

/// What turns a transcript into delivered text: voice commands and the
/// personal lexicon, post-processing, live polish and insertion, and the
/// correction tracker that watches the result.
struct SessionTextServices {
  let textProcessor: TranscriptionTextProcessor
  let personalLexicon: PersonalLexiconService
  let postProcessing: PostProcessingManager
  let livePolish: LivePolishManager
  let liveTextInserter: LiveTextInserter
  let autoCorrectionTracker: AutoCorrectionTracker

  /// Runs voice commands (e.g., "copy pasta" → clipboard content) and the
  /// personal lexicon over the raw transcript, recording what changed.
  @MainActor
  func applyVoiceCommandsAndLexicon(to rawText: String, for session: ActiveSession) -> String {
    let baseText = textProcessor.process(rawText)
    let lexiconContext = PersonalLexiconContext.inferred(for: baseText, destination: nil)
    let corrections = personalLexicon.apply(to: baseText, context: lexiconContext)
    session.personalCorrections = PersonalLexiconHistorySummary(
      applied: corrections.applied,
      suggestions: corrections.suggestions,
      contextTags: Array(lexiconContext.tags).sorted(),
      destinationApplication: lexiconContext.destinationApplication
    )
    session.lexiconContext = lexiconContext
    return corrections.transformedText
  }

  /// A retried transcript, with the personal lexicon reapplied when the
  /// original session applied it.
  @MainActor
  func retryInputText(for retryData: PostProcessingRetryStore.Entry) -> String {
    let baseText = retryData.transcriptionResult.text
    guard retryData.personalCorrections != nil else { return baseText }
    return personalLexicon.apply(to: baseText, context: retryData.lexiconContext).transformedText
  }
}

extension PersonalLexiconContext {
  /// Infers register tags from the words and the destination app.
  static func inferred(for text: String, destination: String?) -> PersonalLexiconContext {
    var tags: Set<String> = []
    let lowered = text.lowercased()
    if lowered.contains("dear ") || lowered.contains("regards") || lowered.contains("sincerely") {
      tags.insert("formal")
    }
    if lowered.contains("meeting") || lowered.contains("agenda")
      || lowered.contains("project") || lowered.contains("quarterly") {
      tags.insert("work")
    }
    if lowered.contains("love") || lowered.contains("babe") || lowered.contains("sweetheart") {
      tags.insert("intimate")
    }
    if let destination, !destination.isEmpty {
      let lowerDest = destination.lowercased()
      if lowerDest.contains("mail") || lowerDest.contains("outlook") { tags.insert("formal") }
      if lowerDest.contains("messages") || lowerDest.contains("imessage") { tags.insert("casual") }
      if lowerDest.contains("slack") || lowerDest.contains("teams") { tags.insert("work") }
    }
    let window = String(text.suffix(400))
    return PersonalLexiconContext(tags: tags, destinationApplication: destination, recentTranscriptWindow: window)
  }
}
