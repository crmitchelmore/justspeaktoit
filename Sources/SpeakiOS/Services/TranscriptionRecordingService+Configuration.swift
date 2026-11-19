#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Capture admission and model routing: the effective configuration a run
/// is admitted with, the model it may use and the refusals that settle it
/// before the microphone opens.
@MainActor
extension TranscriptionRecordingService {
    func admittedConfiguration(
        parameters: CaptureRunParameters,
        keyboardProfile: KeyboardDictationProfileOption?,
        destination: HardwareTriggerDestination?,
        request: CaptureConfigurationRequest?,
        run runID: UUID
    ) async throws -> EffectiveCaptureConfiguration {
        do {
            let configuration = try await prepareCaptureConfiguration(
                parameters: parameters, keyboardProfile: keyboardProfile, destination: destination, request: request
            )
            try requireForegroundUnownedForAcquisition(run: runID)
            try Task.checkCancellation()
            guard lifecycle.isCurrentStartRun(runID) else { throw CancellationError() }
            request?.configuration = configuration
            return configuration
        } catch {
            // Admission has allocated no shared state, activity or microphone.
            disarmWatchdogs()
            diagnostics.finish(outcome(for: error), run: runID)
            presentation.finish()
            completeRun(with: "")
            lifecycle.finishStartUnwind()
            throw error
        }
    }

    func prepareCaptureConfiguration(
        parameters: CaptureRunParameters,
        keyboardProfile: KeyboardDictationProfileOption?,
        destination: HardwareTriggerDestination?,
        request: CaptureConfigurationRequest?
    ) async throws -> EffectiveCaptureConfiguration {
        if let prepared = request?.configuration { return prepared }
        // Read every global before either native lookup or credentials can suspend.
        let selection = Self.modelSelection(keyboardProfile: keyboardProfile, parameters: .none, settings: settings)
        let globals = EffectiveCaptureConfiguration.Globals(
            modelID: selection.modelID, usesBatch: selection.usesBatch,
            languageIdentifier: keyboardProfile?.languageIdentifier ?? settings.preferredLocaleIdentifier,
            destinationID: (destination ?? settings.hardwareTriggerDestination).rawValue
        )
        let explicit = keyboardProfile == nil ? CaptureRunParameters(
            destinationID: destination?.rawValue ?? parameters.destinationID,
            languageIdentifier: parameters.languageIdentifier,
            modelID: parameters.modelID, sourceTag: parameters.sourceTag
        ) : .none
        let focus = keyboardProfile == nil ? try await focusOverride(explicit) : .none
        return try EffectiveCaptureConfiguration.resolve(
            explicit: explicit, focus: focus, globals: globals, vocabulary: CaptureModelSupport.vocabulary
        )
    }

    /// Stores the overrides this run will carry, and logs them so a capture's
    /// parameters are recoverable after the fact.
    ///
    /// The keyboard carries its own profile and never takes intent parameters,
    /// so a keyboard run stores none.
    @discardableResult
    func adoptRunParameters(
        _ parameters: CaptureRunParameters,
        keyboardProfile: KeyboardDictationProfileOption?
    ) -> CaptureRunParameters {
        let adopted = keyboardProfile == nil ? parameters : .none
        currentRunParameters = adopted
        if !adopted.isEmpty {
            // Destination, language and model come from closed vocabularies
            // and are safe as public diagnostics. The source tag is free text
            // a Shortcut variable can fill with anything, so it is logged
            // privately: a caller's label must not become collectable log data.
            SpeakLogger.transcription.info(
                """
                Capture parameters: \(adopted.redactedLogDescription, privacy: .public) \
                source=\(adopted.sourceTag ?? "none", privacy: .private)
                """
            )
        }
        return adopted
    }

    /// Which model this run uses and whether it has to run in batch mode.
    ///
    /// Precedence: the keyboard's own profile, then the caller's per-run
    /// parameters, then the configured settings.
    ///
    /// When the caller *named* a model, the mode follows the model rather than
    /// the Settings toggle. Letting `transcriptionMode == .batch` stand for a
    /// live-only identifier is how a named model reaches the batch uploader,
    /// whose router falls through to OpenRouter for anything it does not
    /// recognise — the recording would then be sent to a provider and in a
    /// mode the caller never asked for. With no model parameter, the
    /// configured mode is used exactly as before.
    static func modelSelection(
        keyboardProfile: KeyboardDictationProfileOption?,
        parameters: CaptureRunParameters,
        settings: AppSettings
    ) -> (modelID: String, usesBatch: Bool) {
        let usesBatch: Bool
        if let keyboardProfile {
            usesBatch = keyboardProfile.transcriptionMode == .batch
        } else if parameters.modelID != nil {
            usesBatch = parameters.requiresBatchMode
        } else {
            usesBatch = settings.transcriptionMode == .batch
        }
        let modelID = keyboardProfile?.transcriptionModelIdentifier
            ?? parameters.modelID
            ?? (usesBatch ? settings.batchTranscriptionModel : settings.selectedModel)
        // A running app crossing a shutdown day follows the automatic successor.
        let successor = ModelRetirements.successor(for: modelID, mode: usesBatch ? .batch : .live)
        return (successor ?? modelID, usesBatch)
    }

    /// Refuses a named model this device cannot honour, before any microphone
    /// is opened.
    ///
    /// Two ways a request can be unhonourable: the model has no execution path
    /// on iOS for the mode this run will use, or it has one but the credential
    /// it needs is not on the device. Both used to be discovered late — the
    /// first by falling through to a different route, the second by throwing
    /// at stop, after the audio had been captured and with a history entry
    /// already written. The parameter contract is that an unusable named value
    /// fails visibly instead, so both are checked here.
    ///
    /// Only applies when a model was actually named: a run with no model
    /// parameter keeps the configured behaviour, including the deliberate
    /// on-device fallback the app makes for its own setting.
    func refuseUnusableRequestedModel(
        _ requestedModelID: String?,
        usesBatch: Bool,
        settings: AppSettings,
        run: UUID
    ) throws {
        guard let requestedModelID else { return }
        guard CaptureModelSupport.canRun(requestedModelID, usesBatch: usesBatch) else {
            unwindCancelledStart(outcome: .failed, run: run)
            SpeakLogger.transcription.error(
                """
                Refusing capture: \(requestedModelID, privacy: .public) has no iOS \
                \(usesBatch ? "batch" : "live", privacy: .public) route
                """
            )
            throw CaptureParameterFailure.modelUnsupported
        }
        guard usesBatch else { return }
        // Mirrors the check `IOSBatchTranscriptionClient.requireAPIKey` makes
        // at stop. Apple's on-device analyzer needs no key and returns "".
        let requirement = ModelCredentialResolver.requirement(
            for: requestedModelID,
            purpose: .batchTranscription
        )
        guard case .apiKey = requirement else { return }
        let key = settings.batchAPIKey(for: requestedModelID)
        guard key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        unwindCancelledStart(outcome: .failed, run: run)
        SpeakLogger.transcription.error(
            "Refusing capture: no API key for \(requestedModelID, privacy: .public)"
        )
        throw CaptureParameterFailure.modelUnavailable
    }

    /// Refuses a live run whose model cannot run here (unsupported route or
    /// missing key) instead of substituting on-device speech. Runs after
    /// offline routing, whose visible fallback needs no key.
    ///
    /// A caller that named a model keeps its ``CaptureParameterFailure`` so
    /// the intent reports it as a parameter; otherwise the error names the
    /// model and why it is unavailable.
    func requireLiveModelAvailable(
        settings: AppSettings,
        requestedModelID: String?,
        run: UUID
    ) throws {
        do {
            try settings.requireTranscriptionAvailable(currentModel, usesBatch: false)
        } catch {
            unwindCancelledStart(outcome: .failed, run: run)
            SpeakLogger.transcription.error(
                "Refusing capture: \(self.currentModel, privacy: .public) is unavailable; not substituting"
            )
            throw requestedModelID == nil ? error : CaptureParameterFailure.modelUnavailable
        }
    }

    /// Applies only a known-offline live decision. The selected preference is
    /// never mutated; `currentModel` belongs to this run and is what History
    /// and the Live Activity already report.
    func applyOfflineRouting(
        usesBatch: Bool,
        binding: OfflineCaptureRequestBinding,
        localeIdentifier: String,
        run: UUID
    ) throws -> Bool {
        let connectivity = self.networkSnapshot()
        let capability = OfflineCaptureRouting.needsLocalCapability(
            usesBatch: usesBatch,
            requestedModelID: self.currentModel,
            connectivity: connectivity
        ) ? self.localRecognitionCapability(localeIdentifier) : .unknown
        let decision = OfflineCaptureRouting.decide(
            usesBatch: usesBatch,
            requestedModelID: self.currentModel,
            binding: binding,
            connectivity: connectivity,
            localCapability: capability
        )
        switch decision {
        case .use(let route):
            if route.notice != nil { self.offlineIntendedModel = self.currentModel }
            self.currentModel = route.modelID
            if let notice = route.notice { self.providerFallbackNotice = notice }
            return route.requiresStrictOnDeviceRecognition
        case .refuse(.explicitRemoteModelUnavailable):
            self.unwindCancelledStart(outcome: .failed, run: run)
            throw CaptureParameterFailure.modelUnavailable
        case .refuse(.localRecognitionUnavailable):
            self.unwindCancelledStart(outcome: .failed, run: run)
            throw iOSTranscriptionError.offlineLocalRecognitionUnavailable
        }
    }

    func validateCredentialAvailability(
        settings: AppSettings,
        usesBatchTranscription: Bool,
        keyboardProfile: KeyboardDictationProfileOption?,
        run: UUID
    ) throws {
        // Ordinary streaming is checked after offline routing, in
        // `requireLiveModelAvailable`, so an offline on-device run needs no key.
        guard usesBatchTranscription || keyboardProfile != nil else { return }
        do {
            try settings.requireAvailableCredentials(
                for: currentModel,
                purpose: usesBatchTranscription ? .batchTranscription : .liveTranscription
            )
        } catch {
            unwindCancelledStart(outcome: .failed, run: run)
            throw error
        }
    }

    /// The destination a stop should use.
    ///
    /// Explicit beats remembered beats global (issue #1013): a Stop that names
    /// a destination wins, otherwise the override the *start* carried travels
    /// with the run, and only then does the one global setting apply. Every
    /// stop path goes through this, so an interruption, a Live Activity button
    /// and the in-app stop all agree.
    public func resolvedStopDestination(
        explicit: HardwareTriggerDestination? = nil
    ) -> HardwareTriggerDestination {
        resolvedStopSelection(explicit: explicit).destination
    }

    func resolvedStopSelection(explicit: HardwareTriggerDestination? = nil) -> CaptureDestinationSelection {
        if let explicit { return CaptureDestinationSelection(destination: explicit, origin: .explicitStop) }
        if let effectiveDestination { return effectiveDestination }
        return CaptureDestinationSelection(destination: settings.hardwareTriggerDestination, origin: .global)
    }

    /// The destination the running capture was started with, or `nil` when the
    /// caller did not override it. Callers that must preserve the legacy
    /// "no destination given" default pass this straight through.
    public var runDestinationOverride: HardwareTriggerDestination? {
        currentRunParameters.destinationID.flatMap(HardwareTriggerDestination.init(rawValue:))
    }
}
#endif
