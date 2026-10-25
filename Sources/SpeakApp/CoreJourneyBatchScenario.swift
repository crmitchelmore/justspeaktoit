#if DEBUG
import SpeakCore

/// Closed, explicit launched-app fixtures. No release build includes these modes.
enum CoreJourneyBatchScenario: String {
    case batchOff
    case batchPolishSuccess
    case batchPolishFailureThenSuccess

    var polishes: Bool { self != .batchOff }

    // Use a real catalogue selection so ordinary model validation/routing runs.
    // The synthetic key and intercept-everything session never reach a provider.
    static let polishModel = ModelCatalog.defaultPostProcessingModel
    static let outputLanguage = "British English"
    static let rawA = "first synthetic words for cleanup"
    static let rawB = "second synthetic words for cleanup"
    static let polishedA = "First synthetic words, cleaned."
    static let polishedB = "Second synthetic words, cleaned."
    static let failureMessage = "Synthetic post-processing rejection"
    static var systemPrompt: String {
        TranscriptCleanupPolicy.systemPrompt(outputLanguage: self.outputLanguage)
    }
}
#endif
