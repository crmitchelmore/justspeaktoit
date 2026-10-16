import Foundation

public struct ApplicationHistoryDiagnosticContext: Codable, Hashable, Sendable {
    public let capturedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let operatingSystem: String
    public let processIdentifier: Int
    public let microphonePermission: String
    public let inputDeviceName: String
    public let providerLabel: String
    public let latencyTier: String
    public let transcriptionMode: String
    public let transcriptionModel: String
    public let postProcessingModel: String
    public let speedMode: String

    public init(
        capturedAt: Date = Date(), appVersion: String, appBuild: String, operatingSystem: String,
        processIdentifier: Int, microphonePermission: String, inputDeviceName: String, providerLabel: String,
        latencyTier: String, transcriptionMode: String, transcriptionModel: String, postProcessingModel: String,
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
