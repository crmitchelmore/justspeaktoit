import Foundation

struct HistoryDiagnosticContext: Codable, Hashable {
  let capturedAt: Date
  let appVersion: String
  let appBuild: String
  let operatingSystem: String
  let processIdentifier: Int
  let microphonePermission: String
  let inputDeviceName: String
  let providerLabel: String
  let latencyTier: String
  let transcriptionMode: String
  let transcriptionModel: String
  let postProcessingModel: String
  let speedMode: String

  init(
    capturedAt: Date = .init(),
    appVersion: String,
    appBuild: String,
    operatingSystem: String,
    processIdentifier: Int,
    microphonePermission: String,
    inputDeviceName: String,
    providerLabel: String,
    latencyTier: String,
    transcriptionMode: String,
    transcriptionModel: String,
    postProcessingModel: String,
    speedMode: String
  ) {
    self.capturedAt = capturedAt
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.operatingSystem = operatingSystem
    self.processIdentifier = processIdentifier
    self.microphonePermission = microphonePermission
    self.inputDeviceName = inputDeviceName
    self.providerLabel = providerLabel
    self.latencyTier = latencyTier
    self.transcriptionMode = transcriptionMode
    self.transcriptionModel = transcriptionModel
    self.postProcessingModel = postProcessingModel
    self.speedMode = speedMode
  }
}
