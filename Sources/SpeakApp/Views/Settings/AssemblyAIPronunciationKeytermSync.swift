import SpeakCore
import Foundation

/// Keeps AssemblyAI keyterms in step with the pronunciation dictionary while an
/// AssemblyAI live model is active.
@MainActor
struct AssemblyAIPronunciationKeytermSync {
  let settings: AppSettings
  let pronunciation: PronunciationManager

  private func seedKeyterms() -> [String] {
    let modernDictionaryTerms = pronunciation.entries
      .filter { !$0.isRegex }
      .map(\.word)
    return AssemblyAIPronunciationKeyterms.seeds(
      modern: modernDictionaryTerms, legacy: Array(settings.ttsPronunciationDictionary.keys))
  }

  /// Merges the pronunciation dictionary's words into the AssemblyAI keyterms.
  func syncFromPronunciation() {
    guard settings.isActiveAssemblyAILiveModel else { return }

    let seedTerms = seedKeyterms()
    let mergedKeyterms = AssemblyAIPronunciationKeyterms.merged(
      current: AssemblyAIPronunciationKeyterms.parse(settings.assemblyAIKeyterms),
      seeds: seedTerms, ignored: settings.assemblyAIIgnoredPronunciationTerms
    ).joined(separator: ", ")
    if mergedKeyterms != settings.assemblyAIKeyterms {
      settings.assemblyAIKeyterms = mergedKeyterms
    }

    syncIgnored(seedTerms: seedTerms)
  }

  /// Remembers the dictionary words the user removed from the keyterms.
  func syncIgnored(seedTerms: [String]? = nil) {
    guard settings.isActiveAssemblyAILiveModel else { return }

    let pronunciationTerms = seedTerms ?? seedKeyterms()
    let updatedIgnored = AssemblyAIPronunciationKeyterms.ignored(
      selected: settings.assemblyAIKeyterms, seeds: pronunciationTerms,
      stored: settings.assemblyAIIgnoredPronunciationTerms)
    if updatedIgnored != settings.assemblyAIIgnoredPronunciationTerms {
      settings.assemblyAIIgnoredPronunciationTerms = updatedIgnored
    }
  }
}
