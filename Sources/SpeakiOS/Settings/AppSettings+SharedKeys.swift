#if os(iOS)
import SpeakCore

extension AppSettings.DefaultsKey {
    /// Names shared with macOS come from `SharedApplicationPreferences`, not a
    /// second list. Each value keeps its existing type and platform-owned
    /// validation/effects. This projection does not add keys to transfer or
    /// automatic sync policies.
    var storageKey: String {
        switch self {
        case .selectedModel: AppSettings.Shared.liveTranscriptionModel.iOS.key
        case .batchTranscriptionModel: AppSettings.Shared.batchTranscriptionModel.iOS.key
        case .postProcessingModel: AppSettings.Shared.postProcessingModel.iOS.key
        case .transcriptionKeywords: AppSettings.Shared.transcriptionKeywords.iOS.key
        case .preferredLocale: AppSettings.Shared.preferredLocale.iOS.key
        case .visualDensity: AppSettings.Shared.visualDensity.iOS.key
        case .postProcessingEnabled: AppSettings.Shared.postProcessingEnabled.iOS.key
        case .handsFreeDictationEnabled: AppSettings.Shared.handsFreeDictationEnabled.iOS.key
        case .keepAudioOnCancel: AppSettings.Shared.keepAudioOnCancel.iOS.key
        default: self.rawValue
        }
    }
}
#endif
