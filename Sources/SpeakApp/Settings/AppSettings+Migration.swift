import Foundation

/// Runtime reload after a data migration replaced the stored preferences.
/// `reloadAfterMigration()` suppresses persistence around these copies.
extension AppSettings {
  func reloadMigrationSelection(_ restored: AppSettings) {
    self.appearance = restored.appearance
    self.transcriptionMode = restored.transcriptionMode
    self.liveTranscriptionModel = restored.liveTranscriptionModel
    self.batchTranscriptionModel = restored.batchTranscriptionModel
    self.localTranscriptionMode = restored.localTranscriptionMode
    self.preferredLocaleIdentifier = restored.preferredLocaleIdentifier
    self.postProcessingEnabled = restored.postProcessingEnabled
    self.assemblyAIKeyterms = restored.assemblyAIKeyterms
    self.transcriptionKeywords = restored.transcriptionKeywords
    self.textOutputMethod = restored.textOutputMethod
    self.appSwitchDelivery = restored.appSwitchDelivery
    self.cancelRecordingOnEscape = restored.cancelRecordingOnEscape
  }

  func reloadMigrationShellAndCapture(_ restored: AppSettings) {
    self.runAtLogin = restored.runAtLogin
    self.recordingsDirectory = restored.recordingsDirectory
    self.selectedHotKey = restored.selectedHotKey
    self.handsFreeDictationEnabled = restored.handsFreeDictationEnabled
    self.connectionPreWarmingEnabled = restored.connectionPreWarmingEnabled
    self.audioPreWarmingEnabled = restored.audioPreWarmingEnabled
    self.warmMicrophoneOnKeyPress = restored.warmMicrophoneOnKeyPress
    self.speedMode = restored.speedMode
    self.streamingInsertionEnabled = restored.streamingInsertionEnabled
    self.analyticsEnabled = restored.analyticsEnabled
    self.recordingSoundProfile = restored.recordingSoundProfile
  }
}
