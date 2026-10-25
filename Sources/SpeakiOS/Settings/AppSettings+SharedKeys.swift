#if os(iOS)
import SpeakCore

extension AppSettings.DefaultsKey {
    /// Share names with macOS's existing catalogue, not defaults or model support.
    /// Each value keeps its existing type and platform-owned validation/effects.
    /// This projection does not add keys to transfer or automatic sync policies.
    var storageKey: String {
        switch self {
        case .batchTranscriptionModel: ApplicationPreferenceKey.batchTranscriptionModel.rawValue
        case .postProcessingModel: ApplicationPreferenceKey.postProcessingModel.rawValue
        case .transcriptionKeywords: ApplicationPreferenceKey.transcriptionKeywords.rawValue
        case .preferredLocale: ApplicationPreferenceKey.preferredLocale.rawValue
        case .postProcessingEnabled: ApplicationPreferenceKey.postProcessingEnabled.rawValue
        case .handsFreeDictationEnabled: ApplicationPreferenceKey.handsFreeDictationEnabled.rawValue
        default: self.rawValue
        }
    }
}
#endif
