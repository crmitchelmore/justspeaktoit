import Foundation
import SpeakCore

/// What a desktop host can execute, read from its live catalogue projections
/// at resolution time. Nothing here is a copied list: a route the host wires
/// later is honoured the next time a profile is resolved.
public struct DesktopProfileCapabilities: Sendable {
    public var batchModels: [ModelCatalog.Option]
    public var liveModels: [ModelCatalog.Option]
    public var polishModels: [ModelCatalog.Option]
    /// Whether the host can layer personal-lexicon directives and context tags
    /// into the polish prompt. Desktop hosts have no personal lexicon yet.
    public var supportsPersonalLexicon: Bool
    /// Whether the host's live sessions accept a spoken-language hint.
    public var supportsLiveLanguage: Bool

    public init(
        batchModels: [ModelCatalog.Option],
        liveModels: [ModelCatalog.Option],
        polishModels: [ModelCatalog.Option],
        supportsPersonalLexicon: Bool = false,
        supportsLiveLanguage: Bool = false
    ) {
        self.batchModels = batchModels
        self.liveModels = liveModels
        self.polishModels = polishModels
        self.supportsPersonalLexicon = supportsPersonalLexicon
        self.supportsLiveLanguage = supportsLiveLanguage
    }

    /// The shared desktop projections: batch routes the desktop transcriber
    /// runs, live routes the desktop session implements and cloud polish
    /// models. A host that has not qualified live transport narrows `liveModels`.
    public static var shared: DesktopProfileCapabilities {
        DesktopProfileCapabilities(
            batchModels: DesktopTranscription.batchModels,
            liveModels: DesktopLiveTranscription.liveModels,
            polishModels: DesktopPostProcessing.remoteModels
        )
    }

    /// Whether `modelID` can run under `routing` exactly as stored: batch
    /// identifiers must be executable batch routes, streaming identifiers
    /// executable live routes, and local models need a local runtime the
    /// desktop hosts do not have.
    public func canRun(transcriptionModel modelID: String, routing: DictationProfileTranscriptionRouting) -> Bool {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch routing {
        case .remoteBatch: return batchModels.contains { $0.id == identifier }
        case .remoteStreaming: return liveModels.contains { $0.id == identifier }
        case .localBatch: return false
        }
    }

    public func canRun(polishModel modelID: String) -> Bool {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return polishModels.contains { $0.id == identifier }
    }

    public func isLive(_ modelID: String) -> Bool {
        liveModels.contains { $0.id == modelID }
    }
}

/// One thing a profile asked for that this host cannot honour. Every
/// limitation is reported to the user; a blocking one refuses to start the
/// recording rather than run a different model in the profile's name.
public enum DesktopProfileLimitation: Equatable, Sendable {
    /// The transcription override cannot run here. Recording is refused so the
    /// audio is never sent to a model or provider the profile did not choose.
    case transcriptionModelUnavailable(modelID: String, routing: DictationProfileTranscriptionRouting)
    /// The polish model cannot run here. Polish is skipped for the session;
    /// no other model is substituted for the one the profile chose.
    case polishModelUnavailable(modelID: String)
    /// The spoken-language override only reaches batch requests; the live
    /// session lets the provider detect the language.
    case languageUnavailableForLiveModel(languageIdentifier: String)
    /// Personal-lexicon directives were requested; the host has no lexicon.
    case lexiconDirectivesUnavailable
    /// Lexicon context tags were requested; the host has no lexicon.
    case contextTagsUnavailable

    public var blocksRecording: Bool {
        if case .transcriptionModelUnavailable = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .transcriptionModelUnavailable(let modelID, let routing):
            let kind: String
            switch routing {
            case .remoteStreaming: kind = "live"
            case .remoteBatch: kind = "batch"
            case .localBatch: kind = "local"
            }
            return "Transcription model \(Self.describe(modelID)) (\(kind)) is not available in this desktop build. "
                + "Recording with this profile is refused until it uses a model this build can run "
                + "or keeps the app setting."
        case .polishModelUnavailable(let modelID):
            return "Polish model \(Self.describe(modelID)) is not available in this desktop build. "
                + "Post-processing is skipped for this profile; no other model runs in its place."
        case .languageUnavailableForLiveModel(let languageIdentifier):
            return "Spoken language “\(languageIdentifier)” applies to batch models only; "
                + "live models in this desktop build detect the language themselves."
        case .lexiconDirectivesUnavailable:
            return "Personal lexicon directives are kept for macOS; this desktop build has no personal lexicon."
        case .contextTagsUnavailable:
            return "Lexicon context tags are kept for macOS; this desktop build has no personal lexicon."
        }
    }

    private static func describe(_ modelID: String) -> String {
        let friendly = ModelCatalog.friendlyName(for: modelID)
        return friendly == modelID || friendly == "—" ? "“\(modelID)”" : "“\(friendly)” (\(modelID))"
    }
}

/// The settings for exactly one recording, copied at recording start. A host
/// keeps this value with the recording and finalises from it, so a global
/// setting changed while the recording is in flight neither alters this
/// session nor is altered by it: profile overrides are never written back.
public struct DesktopProfileSession: Equatable, Sendable {
    /// The profile that matched, or `nil` when the app's normal settings apply.
    public let profileName: String?
    /// The transcription model to record with.
    public let modelIdentifier: String
    /// Provider language for batch transcription; `nil` requests detection.
    public let language: String?
    public let postProcessing: DesktopPostProcessing.Options
    public let limitations: [DesktopProfileLimitation]
    /// Why polish was skipped for this session, for the host to record as the
    /// post-processing outcome so History explains the missing processed text.
    public let skippedPolishReason: String?

    public init(
        profileName: String?,
        modelIdentifier: String,
        language: String?,
        postProcessing: DesktopPostProcessing.Options,
        limitations: [DesktopProfileLimitation] = [],
        skippedPolishReason: String? = nil
    ) {
        self.profileName = profileName
        self.modelIdentifier = modelIdentifier
        self.language = language
        self.postProcessing = postProcessing
        self.limitations = limitations
        self.skippedPolishReason = skippedPolishReason
    }

    /// The app's normal settings with no profile: the shape used for imports
    /// and History retries, which deliberately never resolve a profile.
    public static func defaults(
        modelIdentifier: String, postProcessing: DesktopPostProcessing.Options, language: String? = nil
    ) -> DesktopProfileSession {
        DesktopProfileSession(
            profileName: nil, modelIdentifier: modelIdentifier, language: language, postProcessing: postProcessing
        )
    }

    public var blockingLimitation: DesktopProfileLimitation? {
        limitations.first(where: \.blocksRecording)
    }

    public var canRecord: Bool { blockingLimitation == nil }
}

/// Pure resolution of a profile against the host's defaults and capabilities.
/// Apple keeps `SessionProfileApplier`; this is the same policy expressed as a
/// value so a host without mutable shared settings can adopt it.
public enum DesktopProfileSessionResolver {
    public static func resolve(
        profile: DictationProfile?,
        defaultModel: String,
        defaultPostProcessing: DesktopPostProcessing.Options,
        capabilities: DesktopProfileCapabilities
    ) -> DesktopProfileSession {
        guard let profile else {
            return .defaults(modelIdentifier: defaultModel, postProcessing: defaultPostProcessing)
        }
        var limitations: [DesktopProfileLimitation] = []
        var model = defaultModel
        var effectiveModelIsLive = capabilities.isLive(defaultModel)
        if let override = profile.resolvedTranscriptionOverride {
            if capabilities.canRun(transcriptionModel: override.modelID, routing: override.routing) {
                model = override.modelID
                effectiveModelIsLive = override.routing == .remoteStreaming
            } else {
                limitations.append(
                    .transcriptionModelUnavailable(modelID: override.modelID, routing: override.routing)
                )
            }
        }

        var language: String?
        if let identifier = trimmedNonEmpty(profile.languageIdentifier) {
            if effectiveModelIsLive, !capabilities.supportsLiveLanguage {
                limitations.append(.languageUnavailableForLiveModel(languageIdentifier: identifier))
            } else {
                language = TranscriptionLanguageCatalog.providerLanguage(for: identifier)
            }
        }

        var options = defaultPostProcessing
        var skippedPolishReason: String?
        if let enabled = profile.polishEnabled {
            options.mode = enabled ? .remote : .disabled
        }
        if let requested = trimmedNonEmpty(profile.polishModelID) {
            if capabilities.canRun(polishModel: requested) {
                options.modelIdentifier = requested
            } else {
                let limitation = DesktopProfileLimitation.polishModelUnavailable(modelID: requested)
                limitations.append(limitation)
                if options.mode == .remote {
                    options.mode = .disabled
                    skippedPolishReason = limitation.message
                }
            }
        }
        if let prompt = trimmedNonEmpty(profile.polishPrompt) {
            options.customPrompt = prompt
        }
        if let outputLanguage = trimmedNonEmpty(profile.polishOutputLanguage) {
            options.outputLanguage = outputLanguage
        }
        if options.mode == .remote, !capabilities.supportsPersonalLexicon {
            if profile.polishIncludeLexiconDirectives == true { limitations.append(.lexiconDirectivesUnavailable) }
            if profile.polishIncludeContextTags == true { limitations.append(.contextTagsUnavailable) }
        }
        return DesktopProfileSession(
            profileName: profile.name,
            modelIdentifier: model,
            language: language,
            postProcessing: options,
            limitations: limitations,
            skippedPolishReason: skippedPolishReason
        )
    }

    /// The limitations a profile would meet here regardless of the current
    /// defaults, for an editor to show next to the stored values it preserves.
    /// The spoken-language note appears unless the profile's own override is a
    /// batch model, because only then is it certain to reach the provider.
    public static func limitations(
        of profile: DictationProfile, capabilities: DesktopProfileCapabilities
    ) -> [DesktopProfileLimitation] {
        var limitations: [DesktopProfileLimitation] = []
        var overridesBatchModel = false
        if let override = profile.resolvedTranscriptionOverride {
            if capabilities.canRun(transcriptionModel: override.modelID, routing: override.routing) {
                overridesBatchModel = override.routing == .remoteBatch
            } else {
                limitations.append(
                    .transcriptionModelUnavailable(modelID: override.modelID, routing: override.routing)
                )
            }
        }
        if let identifier = trimmedNonEmpty(profile.languageIdentifier),
           !overridesBatchModel, !capabilities.supportsLiveLanguage {
            limitations.append(.languageUnavailableForLiveModel(languageIdentifier: identifier))
        }
        if let requested = trimmedNonEmpty(profile.polishModelID), !capabilities.canRun(polishModel: requested) {
            limitations.append(.polishModelUnavailable(modelID: requested))
        }
        if profile.polishEnabled != false, !capabilities.supportsPersonalLexicon {
            if profile.polishIncludeLexiconDirectives == true { limitations.append(.lexiconDirectivesUnavailable) }
            if profile.polishIncludeContextTags == true { limitations.append(.contextTagsUnavailable) }
        }
        return limitations
    }

    static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
