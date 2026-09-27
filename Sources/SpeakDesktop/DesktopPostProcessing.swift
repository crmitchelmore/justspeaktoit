import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// Explicit post-processing choices for desktop hosts. Remote and local
/// cleanup are both opt-in; neither missing credentials nor an unsupported
/// model selects a substitute on the other side.
public enum DesktopPostProcessing {
    public enum Mode: String, Codable, Sendable {
        case disabled
        case remote
        /// On this device: built-in rules or a downloaded language model,
        /// named by `modelIdentifier` (`local/post-processing/...`).
        case local
    }

    public struct Options: Codable, Equatable, Sendable {
        public var mode: Mode
        public var modelIdentifier: String
        public var customPrompt: String?
        public var outputLanguage: String?
        public var temperature: Double

        public init(
            mode: Mode = .disabled,
            modelIdentifier: String = ModelCatalog.defaultPostProcessingModel,
            customPrompt: String? = nil,
            outputLanguage: String? = nil,
            temperature: Double = 0.2
        ) {
            self.mode = mode
            self.modelIdentifier = modelIdentifier
            self.customPrompt = customPrompt
            self.outputLanguage = outputLanguage
            self.temperature = temperature
        }
    }

    public struct Outcome: Sendable {
        public let original: String
        public let processedText: String
        public let modelIdentifier: String?
        public let systemPrompt: String?
        public let userPrompt: String?
        public let response: ChatResponse?
    }

    public static var remoteModels: [ModelCatalog.Option] { ModelCatalog.cloudPostProcessing }

    /// Applies the Apple settings' retired-model migration
    /// (`ModelCatalog.normalizedPostProcessingModel`) to persisted options. A
    /// retired cloud model moves to its successor and keeps the user's choice to
    /// send transcripts to the same remote service; a model this host cannot run
    /// (for example a local cleanup model) disables post-processing instead of
    /// substituting a remote one.
    public static func migrated(_ options: Options) -> Options {
        var result = options
        if options.mode == .local {
            // A local choice stays local; whether its download and runtime are
            // ready is checked when it runs, never swapped for a remote model.
            guard DesktopLocalPostProcessing.isLocalIdentifier(options.modelIdentifier) else {
                result.mode = .disabled
                result.modelIdentifier = ModelCatalog.defaultPostProcessingModel
                return result
            }
            return result
        }
        let model = ModelCatalog.normalizedPostProcessingModel(options.modelIdentifier)
        if remoteModels.contains(where: { $0.id == model }) {
            result.modelIdentifier = model
        } else {
            result.mode = .disabled
            result.modelIdentifier = ModelCatalog.defaultPostProcessingModel
        }
        return result
    }

    public static func process(
        rawText: String,
        options: Options,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> Outcome {
        try Task.checkCancellation()
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(rawText) {
            return unchanged(original: rawText, processed: "")
        }
        guard options.mode == .remote else {
            if options.mode == .local { throw DesktopPostProcessingError.localNeedsRuntime }
            return unchanged(original: rawText, processed: rawText)
        }
        let model = options.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteModels.contains(where: { $0.id == model }) else {
            throw DesktopPostProcessingError.unsupportedModel
        }
        guard options.temperature.isFinite, (0...1).contains(options.temperature) else {
            throw DesktopPostProcessingError.invalidTemperature
        }
        let systemPrompt = TranscriptCleanupPolicy.systemPrompt(
            customBasePrompt: options.customPrompt,
            outputLanguage: options.outputLanguage
        )
        let userPrompt = TranscriptCleanupPolicy.userMessage(transcript: rawText)
        let response = try await OpenRouterChatClient(apiKey: apiKey, session: session).sendChat(
            systemPrompt: systemPrompt,
            messages: [.init(role: .user, content: userPrompt)],
            model: model,
            temperature: options.temperature
        )
        try Task.checkCancellation()
        guard let assistant = response.messages.last(where: { $0.role == .assistant }),
              !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterClientError.invalidResponse
        }
        return Outcome(
            original: rawText,
            processedText: assistant.content,
            modelIdentifier: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            response: response
        )
    }

    /// Cleans up on this device. Built-in rules need nothing else and read no
    /// prompt. A downloaded language model receives the user's prompt (or the
    /// default cleanup policy) as its system instruction through
    /// `LocalLanguageModelPrompt`; pass the model's verified file and the
    /// host's runtime. An empty or silent transcript stays empty.
    public static func processLocally(
        rawText: String, options: Options, model: LlamaCppModel?, modelFile: URL?,
        languageModel: DesktopLocalLanguageModel?
    ) async throws -> Outcome {
        try Task.checkCancellation()
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(rawText) {
            return unchanged(original: rawText, processed: "")
        }
        guard options.mode == .local else { throw DesktopPostProcessingError.unsupportedModel }
        let identifier = options.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if identifier == DesktopLocalPostProcessing.builtInRulesID {
            let cleaned = TranscriptPostProcessingPolicy.processLocally(rawText)
            return Outcome(
                original: rawText, processedText: cleaned, modelIdentifier: DesktopLocalPostProcessing.builtInRulesID,
                systemPrompt: nil, userPrompt: nil, response: nil
            )
        }
        guard let model, model.identifier == identifier, let modelFile, let languageModel else {
            throw DesktopPostProcessingError.unsupportedModel
        }
        guard options.temperature.isFinite, (0...1).contains(options.temperature) else {
            throw DesktopPostProcessingError.invalidTemperature
        }
        let systemPrompt = LocalLanguageModelPrompt.systemPrompt(
            customPrompt: options.customPrompt, outputLanguage: options.outputLanguage
        )
        let userPrompt = LocalLanguageModelPrompt.userMessage(transcript: rawText)
        let request = DesktopLocalGeneration(
            systemPrompt: systemPrompt, userMessage: userPrompt, temperature: options.temperature,
            maximumTokens: LocalLanguageModelPrompt.maximumOutputTokens(for: rawText)
        )
        let raw = try await languageModel.generate(request, model: model, modelFile: modelFile)
        try Task.checkCancellation()
        let cleaned = LocalLanguageModelPrompt.sanitizedOutput(raw)
        guard !cleaned.isEmpty else { throw DesktopPostProcessingError.emptyLocalResponse }
        return Outcome(
            original: rawText, processedText: cleaned, modelIdentifier: model.identifier,
            systemPrompt: systemPrompt, userPrompt: userPrompt, response: nil
        )
    }

    private static func unchanged(original: String, processed: String) -> Outcome {
        Outcome(
            original: original, processedText: processed, modelIdentifier: nil,
            systemPrompt: nil, userPrompt: nil, response: nil
        )
    }
}

public enum DesktopPostProcessingError: LocalizedError {
    case unsupportedModel
    case invalidTemperature
    case localNeedsRuntime
    case emptyLocalResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            return "Choose a supported post-processing model."
        case .invalidTemperature:
            return "Post-processing temperature must be between 0 and 1."
        case .localNeedsRuntime:
            return "Local post-processing runs through this device's runtime, not a remote service."
        case .emptyLocalResponse:
            return "The local model returned an empty response."
        }
    }
}

/// One prompt pair for a local language model, with its sampling limits.
public struct DesktopLocalGeneration: Sendable, Equatable {
    public let systemPrompt: String
    public let userMessage: String
    public let temperature: Double
    public let maximumTokens: Int

    public init(systemPrompt: String, userMessage: String, temperature: Double, maximumTokens: Int) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.temperature = temperature
        self.maximumTokens = maximumTokens
    }
}

/// Runs one prompt pair on a downloaded GGUF language model.
public protocol DesktopLocalLanguageModel: Sendable {
    /// Returns the model's reply. Throws `CancellationError` when the calling
    /// task is cancelled before or during generation.
    func generate(_ request: DesktopLocalGeneration, model: LlamaCppModel, modelFile: URL) async throws -> String
}

/// The desktop host's projection of the shared local post-processing
/// catalogue: built-in rules, then pinned catalogue models, then imports.
public enum DesktopLocalPostProcessing {
    public static let builtInRulesID = LocalPostProcessingModel.builtInRulesModelID

    /// The canonical built-in rules entry, described for a desktop host.
    public static var builtInRulesOption: ModelCatalog.Option {
        let name = ModelCatalog.friendlyName(for: builtInRulesID)
        return ModelCatalog.Option(
            id: builtInRulesID, displayName: name,
            description: "Fixes spacing, capitalisation and punctuation on this device with fixed rules. "
                + "It needs no download and ignores the prompt.",
            estimatedLatencyMs: 50, latencyTier: .instant, tags: [.fast, .cheap, .privacy]
        )
    }

    /// Catalogue models the host runs through llama.cpp, in catalogue order,
    /// then the registered imports.
    public static func models(host: LocalModelHostSupport) -> [LlamaCppModel] {
        guard host.canExecute(.llamaCppGGUF) else { return [] }
        let catalogue = host.executableModels(in: ModelCatalog.localPostProcessing).compactMap {
            LlamaCppModels.model(for: $0.id)
        }
        return catalogue + DesktopLocalModelImports.registered.languageModels
    }

    public static func model(for identifier: String, host: LocalModelHostSupport) -> LlamaCppModel? {
        let lowered = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models(host: host).first { $0.identifier == lowered }
    }

    /// Whether an identifier names local post-processing at all (rules, a
    /// catalogue model or an import), whatever this host can run now.
    public static func isLocalIdentifier(_ identifier: String) -> Bool {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .hasPrefix(LocalModelIdentity.postProcessingPrefix)
    }

    /// Whether the prompt editor applies: every local language model follows
    /// the prompt; built-in rules never read it.
    public static func usesPrompt(_ identifier: String) -> Bool {
        isLocalIdentifier(identifier)
            && identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != builtInRulesID
    }

    /// The friendly name shown for a local post-processing identifier.
    public static func displayName(for identifier: String) -> String {
        if let model = LlamaCppModels.model(for: identifier) { return model.displayName }
        if let model = DesktopLocalModelImports.registered.model(for: identifier) { return model.displayName }
        return ModelCatalog.friendlyName(for: identifier)
    }
}
