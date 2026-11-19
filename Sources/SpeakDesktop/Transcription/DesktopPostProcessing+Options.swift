import Foundation
import SpeakCore

// The persisted post-processing choices, a run's outcome and the native
// editor's fields.
extension DesktopPostProcessing {
    public struct Options: Codable, Equatable, Sendable {
        public var mode: Mode
        public var modelIdentifier: String
        public var customPrompt: String?
        public var outputLanguage: String?
        public var temperature: Double
        public var includeLexiconDirectives: Bool
        public var includeContextTags: Bool
        public var streamingEnabled = SpeechDefaults.desktopLegacyPostProcessingStreamingEnabled
        /// Dormant native-picker recall, never an execution route or portable preference.
        public var lastRemoteModelIdentifier: String?

        public init(
            mode: Mode = .disabled,
            modelIdentifier: String = ModelCatalog.defaultPostProcessingModel,
            customPrompt: String? = nil,
            outputLanguage: String? = nil,
            temperature: Double = SpeechDefaults.temperature
        ) {
            self.init(
                mode: mode, modelIdentifier: modelIdentifier, customPrompt: customPrompt,
                outputLanguage: outputLanguage, temperature: temperature,
                includeLexiconDirectives: SpeechDefaults.postProcessingIncludeLexiconDirectives,
                includeContextTags: SpeechDefaults.postProcessingIncludeContextTags
            )
        }

        public init(
            mode: Mode = .disabled,
            modelIdentifier: String = ModelCatalog.defaultPostProcessingModel,
            customPrompt: String? = nil,
            outputLanguage: String? = nil,
            temperature: Double = SpeechDefaults.temperature,
            includeLexiconDirectives: Bool,
            includeContextTags: Bool,
            lastRemoteModelIdentifier: String? = nil
        ) {
            self.mode = mode
            self.modelIdentifier = modelIdentifier
            self.customPrompt = customPrompt
            self.outputLanguage = outputLanguage
            self.temperature = temperature
            self.includeLexiconDirectives = includeLexiconDirectives
            self.includeContextTags = includeContextTags
            self.lastRemoteModelIdentifier = lastRemoteModelIdentifier
                ?? (DesktopPostProcessing.mode(for: modelIdentifier) == .remote ? modelIdentifier : nil)
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mode = try values.decode(Mode.self, forKey: .mode)
            modelIdentifier = try values.decode(String.self, forKey: .modelIdentifier)
            customPrompt = try values.decodeIfPresent(String.self, forKey: .customPrompt)
            outputLanguage = try values.decodeIfPresent(String.self, forKey: .outputLanguage)
            temperature = try values.decode(Double.self, forKey: .temperature)
            includeLexiconDirectives = values.contains(.includeLexiconDirectives)
                ? try values.decode(Bool.self, forKey: .includeLexiconDirectives)
                : SpeechDefaults.postProcessingIncludeLexiconDirectives
            includeContextTags = values.contains(.includeContextTags)
                ? try values.decode(Bool.self, forKey: .includeContextTags)
                : SpeechDefaults.postProcessingIncludeContextTags
            streamingEnabled = try values.decodeIfPresent(Bool.self, forKey: .streamingEnabled)
                ?? SpeechDefaults.desktopLegacyPostProcessingStreamingEnabled
            lastRemoteModelIdentifier = try values.decodeIfPresent(String.self, forKey: .lastRemoteModelIdentifier)
                ?? (DesktopPostProcessing.mode(for: modelIdentifier) == .remote ? modelIdentifier : nil)
        }

        public func lexiconContext(
            directives: [String], tags: [String]
        ) -> (directives: [String], tags: [String]) {
            let usesContext = mode == .remote || mode == .localLLM
            return (usesContext && includeLexiconDirectives ? directives : [],
                    usesContext && includeContextTags ? tags : [])
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

    public struct NativeFields: Sendable {
        public let prompt: String
        public let key: String
        public let includeLexiconDirectives: Bool
        public let includeContextTags: Bool

        public init(prompt: String, key: String, includeLexiconDirectives: Bool, includeContextTags: Bool) {
            self.prompt = prompt
            self.key = key
            self.includeLexiconDirectives = includeLexiconDirectives
            self.includeContextTags = includeContextTags
        }
    }
}

extension DesktopPostProcessing.Options {
    private enum CodingKeys: String, CodingKey {
        case mode, modelIdentifier, customPrompt, outputLanguage, temperature
        case includeLexiconDirectives, includeContextTags
        case streamingEnabled
        case lastRemoteModelIdentifier
    }
}
