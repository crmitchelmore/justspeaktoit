import SpeakCore

extension LiveClientOptions {
    public static var desktopDefaults: Self {
        Self().capturingPronunciationKeyterms(.init(current: [], legacy: [], ignored: []))
    }

    /// Preserve configured provider controls while adding context-eligible vocabulary.
    public func includingVocabularyKeywords(_ words: [String]) -> LiveClientOptions {
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        return LiveClientOptions(
            keywords: unique(keywords + words),
            assemblyAIKeyterms: unique(assemblyAIKeyterms + words),
            modulate: modulate, postStopFinalizeBudget: postStopFinalizeBudget, stopGracePeriod: stopGracePeriod
        ).capturingPronunciationKeyterms(pronunciationKeyterms)
    }
}
