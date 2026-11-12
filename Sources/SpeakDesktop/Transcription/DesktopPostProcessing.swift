import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// Explicit post-processing choices for desktop hosts. Remote cleanup is opt-in;
/// neither missing credentials nor an unsupported model selects a local substitute.
/// The persisted options and results live in DesktopPostProcessing+Options.swift.
public enum DesktopPostProcessing {
    public enum Mode: String, Codable, Sendable {
        case disabled
        case remote
        case local
        case localLLM
    }

    /// Native provider routes first, then OpenRouter routes labelled as such.
    public static var remoteModels: [ModelCatalog.Option] {
        ModelPickerGrouping.flattened(CleanupModelDiscoveryStore.shared.options(), purpose: .postProcessing)
    }

    public static var localModels: [ModelCatalog.Option] {
        ModelCatalog.postProcessing.filter { $0.id == LocalPostProcessingModel.builtInRulesModelID }
    }

    /// Append local routes so existing remote callback indexes keep their meaning.
    public static var models: [ModelCatalog.Option] { remoteModels + localModels }

    public static func nativeModels(selected: String? = nil) -> [ModelCatalog.Option] {
        nativeModels(selected: selected, rememberedRemote: nil)
    }

    public static func nativeModels(selected: String?, rememberedRemote: String?) -> [ModelCatalog.Option] {
        var remote = CleanupModelDiscoveryStore.shared.options(selected: selected)
        if let rememberedRemote, !remote.contains(where: { $0.id == rememberedRemote }),
           let retained = CleanupModelSelection.retainedOption(rememberedRemote) { remote.append(retained) }
        return ModelPickerGrouping.flattened(remote, purpose: .postProcessing) + localModels
            + DesktopLocalLLMModels.choices(selected: selected).filter {
            LocalPostProcessingModel.isDownloadedModelID($0.id)
        }
    }

    public static let localRulesNotice =
        "Local cleanup runs offline. Built-in rules ignore custom instructions, output language and lexicon context. "
        + "Your remote instructions and context switches are kept. No API key or runtime installation is needed."

    public static func nativeFields(_ encoded: String) throws -> NativeFields {
        let fields = encoded.components(separatedBy: "\t")
        guard fields.count == 4, let prompt = fields[0].removingPercentEncoding,
              let key = fields[1].removingPercentEncoding,
              ["0", "1"].contains(fields[2]), ["0", "1"].contains(fields[3]) else {
            throw DesktopPostProcessingError.invalidEditor
        }
        return NativeFields(
            prompt: prompt, key: key,
            includeLexiconDirectives: fields[2] == "1", includeContextTags: fields[3] == "1"
        )
    }

    public static func mode(for modelIdentifier: String) -> Mode? {
        if localModels.contains(where: { $0.id == modelIdentifier }) { return .local }
        if LocalPostProcessingModel.isDownloadedModelID(modelIdentifier) { return .localLLM }
        return CleanupModelSelection.modelID(from: modelIdentifier) != nil
            || remoteModels.contains(where: { $0.id == modelIdentifier }) ? .remote : nil
    }

    public static func modelIdentifier(forSelection index: Int) -> String? {
        let choices = models
        return choices.indices.contains(index) ? choices[index].id : nil
    }

    public static func selection(for options: Options) -> Int? {
        models.firstIndex { $0.id == options.modelIdentifier }
    }

    public static func remoteSelection(for options: Options) -> Int? {
        let identifier = mode(for: options.modelIdentifier) == .remote
            ? options.modelIdentifier : options.lastRemoteModelIdentifier
        guard let identifier, mode(for: identifier) == .remote else { return nil }
        return nativeModels(selected: options.modelIdentifier, rememberedRemote: options.lastRemoteModelIdentifier)
            .firstIndex { $0.id == identifier }
    }

    /// Applies the Apple settings' retired-model migration
    /// (`ModelCatalog.normalizedPostProcessingModel`) to persisted options. A
    /// retired cloud model moves to its successor and keeps the user's choice to
    /// send transcripts to the same remote service; a model this host cannot run
    /// disables post-processing and retains its identifier instead of substituting
    /// a remote model. An explicit local choice never migrates to a cloud route.
    public static func migrated(_ options: Options) -> Options {
        var result = options
        let stored = options.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode(for: stored) == .local {
            result.modelIdentifier = stored
            if result.mode != .disabled { result.mode = .local }
        } else if mode(for: stored) == .localLLM {
            result.modelIdentifier = stored
            if result.mode != .disabled, result.mode != .localLLM { result.mode = .disabled }
        } else if isLocalIdentifier(stored) || options.mode == .local || options.mode == .localLLM {
            result.mode = .disabled
            result.modelIdentifier = stored
        } else {
            let model = ModelCatalog.normalizedPostProcessingModel(stored)
            result.modelIdentifier = model
        }
        // A remembered remote choice of a removed model keeps its route via its successor.
        if let remembered = result.lastRemoteModelIdentifier {
            result.lastRemoteModelIdentifier = ModelCatalog.currentPostProcessingModel(remembered)
        }
        if result.lastRemoteModelIdentifier == nil, mode(for: result.modelIdentifier) == .remote {
            result.lastRemoteModelIdentifier = result.modelIdentifier
        }
        return result
    }

    public static func isLocalIdentifier(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        return lower.hasPrefix("local/") || lower.hasPrefix("apple/local/")
            || lower == AppleLocalModels.foundationModelID.lowercased()
    }

    public static func process(
        rawText: String,
        options: Options,
        apiKey: String,
        lexiconDirectives: [String] = [],
        lexiconContextTags: [String] = [],
        session: URLSession = .shared
    ) async throws -> Outcome {
        try await process(
            rawText: rawText, options: options, apiKey: apiKey, lexiconDirectives: lexiconDirectives,
            lexiconContextTags: lexiconContextTags, session: session, localLLM: nil
        )
    }

    public static func process(
        rawText: String, options: Options, apiKey: String,
        lexiconDirectives: [String] = [], lexiconContextTags: [String] = [],
        session: URLSession = .shared, localLLM: (any DesktopLocalLLMEngine)?
    ) async throws -> Outcome {
        try await process(
            rawText: rawText, options: options, apiKey: apiKey,
            lexiconDirectives: lexiconDirectives, lexiconContextTags: lexiconContextTags,
            session: session, localLLM: localLLM, onUpdate: { _ in }
        )
    }

    // existing owned post-processing dispatch surface; no behavior change.
    // swiftlint:disable:next function_body_length
    public static func process(
        rawText: String, options: Options, apiKey: String,
        lexiconDirectives: [String] = [], lexiconContextTags: [String] = [],
        session: URLSession = .shared, localLLM: (any DesktopLocalLLMEngine)?,
        onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> Outcome {
        try Task.checkCancellation()
        if TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(rawText) {
            return unchanged(original: rawText, processed: "")
        }
        guard options.mode != .disabled else { return unchanged(original: rawText, processed: rawText) }
        let model = options.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode(for: model) == options.mode else {
            throw DesktopPostProcessingError.unsupportedModel
        }
        if options.mode == .local {
            let processed = TranscriptPostProcessingPolicy.processLocally(rawText)
            try Task.checkCancellation()
            return Outcome(
                original: rawText, processedText: processed, modelIdentifier: model,
                systemPrompt: nil, userPrompt: nil, response: nil
            )
        }
        guard options.temperature.isFinite, (0...1).contains(options.temperature) else {
            throw DesktopPostProcessingError.invalidTemperature
        }
        let context = options.lexiconContext(directives: lexiconDirectives, tags: lexiconContextTags)
        let systemPrompt = TranscriptCleanupPolicy.systemPrompt(
            customBasePrompt: options.customPrompt,
            outputLanguage: options.outputLanguage,
            lexiconDirectives: context.directives,
            lexiconContextTags: context.tags
        )
        let userPrompt = TranscriptCleanupPolicy.userMessage(transcript: rawText)
        if options.mode == .localLLM {
            guard let localLLM else {
                throw LocalLLMError.runtimeUnavailable("This host has no native llama.cpp adapter.")
            }
            let output = try await localLLM.complete(
                modelIdentifier: model, systemPrompt: systemPrompt, userPrompt: userPrompt,
                temperature: options.temperature
            )
            try Task.checkCancellation()
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalLLMError.invalidOutput
            }
            return Outcome(
                original: rawText, processedText: output, modelIdentifier: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt, response: nil
            )
        }
        let client = OpenRouterChatClient(apiKey: apiKey, session: session)
        let response: ChatResponse
        if options.streamingEnabled {
            response = try await client.sendChatStreaming(
                systemPrompt: systemPrompt, messages: [.init(role: .user, content: userPrompt)],
                model: model, temperature: options.temperature, onUpdate: onUpdate
            )
        } else {
            response = try await client.sendChat(
                systemPrompt: systemPrompt, messages: [.init(role: .user, content: userPrompt)],
                model: model, temperature: options.temperature
            )
        }
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

    private static func unchanged(original: String, processed: String) -> Outcome {
        Outcome(
            original: original, processedText: processed, modelIdentifier: nil,
            systemPrompt: nil, userPrompt: nil, response: nil
        )
    }
}

package final class DesktopPostProcessingPicker: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String] = []

    package init() {}

    package func publish(_ models: [ModelCatalog.Option]) {
        lock.withLock { identifiers = models.map(\.id) }
    }

    package func modelIdentifier(forSelection index: Int) -> String? {
        lock.withLock { identifiers.indices.contains(index) ? identifiers[index] : nil }
    }
}

public enum DesktopPostProcessingError: LocalizedError {
    case unsupportedModel
    case invalidTemperature
    case invalidEditor

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            return "Choose a supported post-processing model for the selected Local or Remote source."
        case .invalidTemperature:
            return "Post-processing temperature must be between 0 and 1."
        case .invalidEditor:
            return "The post-processing editor sent invalid choices. Reopen it and try again."
        }
    }
}
