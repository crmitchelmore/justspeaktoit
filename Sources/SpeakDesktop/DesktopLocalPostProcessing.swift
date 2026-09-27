import Foundation
import SpeakCore

/// What a local language model produced for one request.
public struct DesktopLocalGeneration: Equatable, Sendable {
    public let text: String
    /// The output reached the generation budget and may be incomplete.
    public let truncated: Bool

    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }
}

/// Runs one downloaded GGUF model over a system instruction and a user message.
public protocol DesktopLocalLanguageModel: Sendable {
    /// Throws `CancellationError` when the calling task is cancelled.
    func generate(
        systemPrompt: String, userMessage: String, model: LlamaCppModel, modelFile: URL,
        temperature: Double, maximumTokens: Int
    ) async throws -> DesktopLocalGeneration
}

public enum DesktopLocalPostProcessingError: LocalizedError, Equatable {
    case unsupportedModel(String)
    case emptyResponse
    case runtimeUnavailable(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let model):
            return "\(ModelCatalog.friendlyName(for: model)) cannot run for local post-processing on this PC."
        case .emptyResponse:
            return "The local model returned an empty response. The original transcript is kept."
        case .runtimeUnavailable(let detail):
            return "The local post-processing runtime (llama.cpp) is unavailable. \(detail)"
        case .generationFailed(let detail):
            return "Local post-processing failed: \(detail)"
        }
    }
}

/// Local transcript cleanup for desktop hosts: the built-in rules, or a
/// downloaded GGUF model from the shared catalogue or a verified import.
///
/// The user's post-processing prompt is the model's system instruction, exactly
/// as the remote path builds it (`TranscriptCleanupPolicy.systemPrompt`), plus
/// the shared local-engine constraint. The transcript goes in the user message
/// as inert JSON data. Built-in rules cannot follow a prompt and ignore it;
/// hosts say so beside the prompt editor (`rulesIgnorePromptNotice`).
public enum DesktopLocalPostProcessing {
    public static let rulesModelID = LocalPostProcessingModel.builtInRulesModelID

    /// Shown beside the prompt editor while built-in rules are selected.
    public static let rulesIgnorePromptNotice =
        "Built-in rules clean up punctuation, spacing and capitalisation with fixed rules. They ignore the prompt; "
        + "choose a downloaded model to have the prompt followed."

    /// Shown beside the prompt editor while a downloaded model is selected.
    public static let localPromptNotice =
        "The prompt is the local model's system instruction. Small local models can ignore strict formatting or "
        + "style instructions; a larger model follows them more reliably."

    /// Built-in rules or any `local/post-processing/...` identifier.
    public static func isLocalModelID(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == rulesModelID || LocalPostProcessingModel.isDownloadedModelID(trimmed)
    }

    /// The canonical built-in rules option.
    public static var rulesOption: ModelCatalog.Option {
        ModelCatalog.postProcessing.first { $0.id == rulesModelID }
            ?? ModelCatalog.Option(
                id: rulesModelID, displayName: "Local Cleanup (Offline)", description: nil, latencyTier: .fast
            )
    }

    /// The pinned catalogue GGUF models a host with `host` can run, in catalogue order.
    public static func catalogueModels(host: LocalModelHostSupport) -> [LlamaCppModel] {
        guard host.canExecute(.llamaCppGGUF) else { return [] }
        return host.executableModels(in: ModelCatalog.localPostProcessing).compactMap {
            LlamaCppModels.model(forCatalogueID: $0.id)
        }
    }

    /// The system instruction and user message a downloaded model receives.
    public static func prompts(rawText: String, options: DesktopPostProcessing.Options) -> (system: String, user: String) {
        let system = TranscriptCleanupPolicy.systemPrompt(
            customBasePrompt: options.customPrompt, outputLanguage: options.outputLanguage
        )
        return (
            LocalPostProcessingPrompt.systemInstruction(system),
            TranscriptCleanupPolicy.userMessage(transcript: rawText)
        )
    }

    /// Built-in rules cleanup. The prompt is not used.
    public static func processWithRules(rawText: String) -> DesktopPostProcessing.Outcome {
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(rawText) {
            return outcome(original: rawText, processed: "", model: nil, system: nil, user: nil)
        }
        return outcome(
            original: rawText, processed: TranscriptPostProcessingPolicy.processLocally(rawText), model: rulesModelID,
            system: nil, user: nil
        )
    }

    /// Runs a downloaded model. Empty or silent input stays empty and never
    /// reaches the model; an empty or reasoning-only response is an error, so
    /// the original transcript is kept instead of a blank.
    public static func process(
        rawText: String, options: DesktopPostProcessing.Options, model: LlamaCppModel, modelFile: URL,
        languageModel: DesktopLocalLanguageModel
    ) async throws -> DesktopPostProcessing.Outcome {
        try Task.checkCancellation()
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(rawText) {
            return outcome(original: rawText, processed: "", model: nil, system: nil, user: nil)
        }
        guard options.temperature.isFinite, (0...1).contains(options.temperature) else {
            throw DesktopPostProcessingError.invalidTemperature
        }
        let (system, user) = prompts(rawText: rawText, options: options)
        let generation = try await languageModel.generate(
            systemPrompt: system, userMessage: user, model: model, modelFile: modelFile,
            temperature: options.temperature, maximumTokens: LocalPostProcessingPrompt.maximumOutputTokens(for: rawText)
        )
        try Task.checkCancellation()
        let cleaned = LocalPostProcessingPrompt.sanitizedOutput(generation.text)
        guard !cleaned.isEmpty else { throw DesktopLocalPostProcessingError.emptyResponse }
        return outcome(original: rawText, processed: cleaned, model: model.catalogueID, system: system, user: user)
    }

    /// The request framing `jsti-llama-runner` reads on standard input: the
    /// system instruction's UTF-8 byte count, a newline, the instruction, then
    /// the user message to the end of input.
    public static func runnerRequest(systemPrompt: String, userMessage: String) -> Data {
        let system = Data(systemPrompt.utf8)
        var data = Data("\(system.count)\n".utf8)
        data.append(system)
        data.append(Data(userMessage.utf8))
        return data
    }

    /// Reads the runner's output. Standard error carries `JSTI_TRUNCATED` on
    /// its own line when generation hit the budget.
    public static func runnerGeneration(standardOutput: Data, standardError: Data) -> DesktopLocalGeneration {
        let errors = String(decoding: standardError, as: UTF8.self)
        let truncated = errors.split(whereSeparator: \.isNewline).contains { $0 == "JSTI_TRUNCATED" }
        return DesktopLocalGeneration(text: String(decoding: standardOutput, as: UTF8.self), truncated: truncated)
    }

    /// A readable failure for a runner exit status, with its last diagnostic.
    public static func runnerFailure(status: Int32, standardError: Data) -> DesktopLocalPostProcessingError {
        let detail = String(decoding: standardError, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
            .last { !$0.isEmpty && $0 != "JSTI_TRUNCATED" } ?? ""
        switch status {
        case 3: return .generationFailed("The model could not be loaded. \(detail)")
        case 4: return .generationFailed("The transcript is too long for this model's context window.")
        case 6: return .generationFailed("The model's chat template is not supported by the bundled llama.cpp.")
        default: return .generationFailed(detail.isEmpty ? "The runner exited with status \(status)." : detail)
        }
    }

    private static func outcome(
        original: String, processed: String, model: String?, system: String?, user: String?
    ) -> DesktopPostProcessing.Outcome {
        DesktopPostProcessing.Outcome(
            original: original, processedText: processed, modelIdentifier: model,
            systemPrompt: system, userPrompt: user, response: nil
        )
    }
}
