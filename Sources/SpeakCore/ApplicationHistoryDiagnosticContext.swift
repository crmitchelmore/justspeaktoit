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
    /// Requested configuration at admission; never an inferred provider handoff.
    public let requestContext: RequestDiagnosticContext?
    /// Observed client invocation only; not proof of remote acceptance or wrapped transport.
    public let observedHandoff: RequestDiagnosticContext?
    public let requestFailure: RequestDiagnosticContext.Failure?

    public init(
        capturedAt: Date = Date(), appVersion: String, appBuild: String, operatingSystem: String,
        processIdentifier: Int, microphonePermission: String, inputDeviceName: String, providerLabel: String,
        latencyTier: String, transcriptionMode: String, transcriptionModel: String, postProcessingModel: String,
        speedMode: String
    ) {
        self.init(
            capturedAt: capturedAt, appVersion: appVersion, appBuild: appBuild, operatingSystem: operatingSystem,
            processIdentifier: processIdentifier, microphonePermission: microphonePermission,
            inputDeviceName: inputDeviceName, providerLabel: providerLabel, latencyTier: latencyTier,
            transcriptionMode: transcriptionMode, transcriptionModel: transcriptionModel,
            postProcessingModel: postProcessingModel, speedMode: speedMode, requestContext: nil
        )
    }

    public init(
        capturedAt: Date = Date(), appVersion: String, appBuild: String, operatingSystem: String,
        processIdentifier: Int, microphonePermission: String, inputDeviceName: String, providerLabel: String,
        latencyTier: String, transcriptionMode: String, transcriptionModel: String, postProcessingModel: String,
        speedMode: String, requestContext: RequestDiagnosticContext?
    ) {
        self.init(
            capturedAt: capturedAt, appVersion: appVersion, appBuild: appBuild, operatingSystem: operatingSystem,
            processIdentifier: processIdentifier, microphonePermission: microphonePermission,
            inputDeviceName: inputDeviceName, providerLabel: providerLabel, latencyTier: latencyTier,
            transcriptionMode: transcriptionMode, transcriptionModel: transcriptionModel,
            postProcessingModel: postProcessingModel, speedMode: speedMode, requestContext: requestContext,
            observedHandoff: nil, requestFailure: nil
        )
    }

    public init(
        capturedAt: Date = Date(), appVersion: String, appBuild: String, operatingSystem: String,
        processIdentifier: Int, microphonePermission: String, inputDeviceName: String, providerLabel: String,
        latencyTier: String, transcriptionMode: String, transcriptionModel: String, postProcessingModel: String,
        speedMode: String, requestContext: RequestDiagnosticContext?, observedHandoff: RequestDiagnosticContext?,
        requestFailure: RequestDiagnosticContext.Failure?
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
        self.requestContext = requestContext
        self.observedHandoff = observedHandoff?.provenance == .observedHandoff ? observedHandoff : nil
        self.requestFailure = requestFailure
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            capturedAt: try values.decode(Date.self, forKey: .capturedAt),
            appVersion: try values.decode(String.self, forKey: .appVersion),
            appBuild: try values.decode(String.self, forKey: .appBuild),
            operatingSystem: try values.decode(String.self, forKey: .operatingSystem),
            processIdentifier: try values.decode(Int.self, forKey: .processIdentifier),
            microphonePermission: try values.decode(String.self, forKey: .microphonePermission),
            inputDeviceName: try values.decode(String.self, forKey: .inputDeviceName),
            providerLabel: try values.decode(String.self, forKey: .providerLabel),
            latencyTier: try values.decode(String.self, forKey: .latencyTier),
            transcriptionMode: try values.decode(String.self, forKey: .transcriptionMode),
            transcriptionModel: try values.decode(String.self, forKey: .transcriptionModel),
            postProcessingModel: try values.decode(String.self, forKey: .postProcessingModel),
            speedMode: try values.decode(String.self, forKey: .speedMode),
            // Future/invalid diagnostics must not discard otherwise valid user History.
            requestContext: try? values.decodeIfPresent(RequestDiagnosticContext.self, forKey: .requestContext),
            observedHandoff: try? values.decodeIfPresent(RequestDiagnosticContext.self, forKey: .observedHandoff),
            requestFailure: try? values.decodeIfPresent(RequestDiagnosticContext.Failure.self, forKey: .requestFailure)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt, appVersion, appBuild, operatingSystem, processIdentifier, microphonePermission
        case inputDeviceName, providerLabel, latencyTier, transcriptionMode, transcriptionModel
        case postProcessingModel, speedMode, requestContext, observedHandoff, requestFailure
    }

    public func hash(into hasher: inout Hasher) {
        // Keep the existing Hashable API while the shared request value is Equatable.
        // Equality includes optional request metadata; unequal snapshots may share a hash.
        hasher.combine(capturedAt)
        hasher.combine(appVersion)
        hasher.combine(appBuild)
        hasher.combine(operatingSystem)
        hasher.combine(processIdentifier)
        hasher.combine(microphonePermission)
        hasher.combine(inputDeviceName)
        hasher.combine(providerLabel)
        hasher.combine(latencyTier)
        hasher.combine(transcriptionMode)
        hasher.combine(transcriptionModel)
        hasher.combine(postProcessingModel)
        hasher.combine(speedMode)
    }
}
