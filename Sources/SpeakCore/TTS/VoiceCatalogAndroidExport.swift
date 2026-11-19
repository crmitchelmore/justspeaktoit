import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The cloud voices Android reads aloud with, as JSON, so Android keeps no copy of voice
/// identifiers, names, endpoints, headers or request bodies.
///
/// Each voice carries a request template built by the shared provider request builders (the same
/// calls the desktop host's `DesktopSpeechSynthesis` makes, at normal speed and default quality)
/// with placeholder text, key, region and language. Android substitutes `{text}`, `{key}`,
/// `{region}` and `{language}`, sends one request per segment of at most `maxCharacters`, and joins
/// the returned 16-bit mono PCM, exactly as the desktop joins WAV segments.
///
/// Offered: the fixed voices of every provider the desktop host synthesises over plain HTTPS
/// (Deepgram, Azure Speech, xAI, Cartesia, Soniox, Gemini, Groq, Speechmatics and ElevenLabs);
/// `accountVoices`, how Android lists the voices of a Mistral, xAI or Soniox account with the saved
/// key and the request each listed voice sends (`{voice}` is its API identifier); and `realtime`,
/// the OpenAI Realtime WebSocket session and its voices.
/// Not offered: voices whose model has an announced retirement (Android has no saved-selection
/// migration, so it never starts offering a model about to shut down, which excludes OpenAI's
/// speech-API voices).
///
/// `VoiceCatalogAndroidExportTests` fails when the committed asset is stale; regenerate it with
/// `UPDATE_VOICE_CATALOG_ANDROID=1 swift test --filter VoiceCatalogAndroidExportTests`.
public enum VoiceCatalogAndroidExport {
    static let textToken = "JSTITEXTTOKEN"
    static let keyToken = "JSTIKEYTOKEN"
    static let regionToken = "jstiregiontoken"
    static let voiceToken = "JSTIVOICETOKEN"
    static let nameToken = "JSTINAMETOKEN"

    static let textPlaceholder = "{text}"
    static let keyPlaceholder = "{key}"
    static let regionPlaceholder = "{region}"
    static let languagePlaceholder = "{language}"
    static let voicePlaceholder = "{voice}"
    static let namePlaceholder = "{name}"

    /// HTTP statuses after which a dialogue-only ElevenLabs request is retried on its fallback model.
    static let dialogueFallbackStatuses = [400, 403, 404, 422]

    struct Template: Encodable, Equatable {
        let method: String
        let url: String
        let headers: [String: String]
        /// A JSON body whose string values may be `{text}` or `{language}`.
        let jsonBody: AnyCodable?
        /// An SSML body; Android XML-escapes the text it puts in place of `{text}`.
        let xmlBody: String?
    }

    struct Dialogue: Encodable, Equatable {
        let maxCharacters: Int
        let request: Template
        let fallbackStatuses: [Int]
    }

    struct Voice: Encodable, Equatable {
        /// Unique across the catalogue: `modelID|id`.
        let key: String
        let id: String
        let name: String
        let label: String
        let provider: String
        let providerName: String
        let modelID: String
        let credentialID: String
        let sampleRate: Int
        let maxCharacters: Int
        let maxSegments: Int?
        /// `wav`, or `geminiInteraction` for an Interactions response carrying base64 L16.
        let response: String
        let request: Template
        /// ElevenLabs dialogue-only models: used when the whole text fits, else `request` is.
        let dialogue: Dialogue?
    }

    struct PronunciationDefault: Encodable, Equatable {
        let word: String
        let pronunciation: String
        let replacement: String?
        let category: String?
        let isRegex: Bool
        let caseSensitive: Bool
    }

    struct Document: Encodable {
        let version: Int
        let voices: [Voice]
        let accountVoices: [AccountProvider]
        let realtime: Realtime
        /// `PronunciationEntry.defaultEntries` without identities, which Android assigns on first use.
        let pronunciationDefaults: [PronunciationDefault]
    }

    public static func json() throws -> Data {
        let document = Document(
            version: 1,
            voices: try voices(),
            accountVoices: try accountProviders(),
            realtime: try realtime(),
            pronunciationDefaults: pronunciationDefaults
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    static var pronunciationDefaults: [PronunciationDefault] {
        PronunciationEntry.defaultEntries.map {
            PronunciationDefault(
                word: $0.word, pronunciation: $0.pronunciation, replacement: $0.replacement,
                category: $0.category, isRegex: $0.isRegex, caseSensitive: $0.caseSensitive
            )
        }
    }

    static func voices() throws -> [Voice] {
        try DesktopSpeechVoice.voices.compactMap(exported)
    }

    // The Android provider (its `cloud_catalog.json` id) and display name, or nil when not offered.
    // One case per speech provider; splitting it would hide a provider added to `DesktopSpeechVoice`.
    // swiftlint:disable:next cyclomatic_complexity
    static func provider(of voice: DesktopSpeechVoice) -> (id: String, name: String)? {
        guard !isLeftOut(voice) else { return nil }
        switch voice {
        case .deepgram: return ("deepgram", "Deepgram")
        case .azureNeural, .azureMAI: return ("azure", "Azure Speech")
        case .xai: return ("xai", "xAI")
        case .cartesia: return ("cartesia", "Cartesia")
        case .soniox: return ("soniox", "Soniox")
        case .gemini: return ("google", "Google Gemini")
        case .groq: return ("groq", "Groq")
        case .speechmatics: return ("speechmatics", "Speechmatics")
        case .elevenlabs: return ("elevenlabs", "ElevenLabs")
        case .mistral, .openai, .openaiRealtime: return nil
        }
    }

    /// Retiring models and account-discovered voices, which Android cannot list.
    private static func isLeftOut(_ voice: DesktopSpeechVoice) -> Bool {
        if ModelRetirements.retirement(for: voice.modelID) != nil { return true }
        if case .soniox(let resolved) = voice { return resolved.accountVoice != nil }
        return false
    }

    // One branch per provider, mirroring `DesktopSpeechSynthesis.synthesize`.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func exported(_ voice: DesktopSpeechVoice) throws -> Voice? {
        guard let provider = provider(of: voice) else { return nil }
        let sampleRate = voice.sampleRate(quality: nil)
        var maxCharacters = DeepgramSpeechRequest.maximumCharacters
        var maxSegments: Int?
        var response = "wav"
        var dialogue: Dialogue?
        let request: Template
        switch voice {
        case .deepgram(let selected):
            request = try template(DeepgramTTSAPI.speakRequest(
                text: textToken, apiKey: keyToken,
                queryItems: DeepgramSpeechSynthesizer.queryItems(for: selected, sampleRate: sampleRate)
            ))
        case .azureNeural, .azureMAI:
            request = try template(AzureSpeechVoiceAPI.synthesisRequest(
                credentials: "\(keyToken):\(regionToken)", text: textToken, voice: voice.id,
                format: "riff-\(sampleRate / 1000)khz-16bit-mono-pcm"
            ), xml: true)
        case .xai:
            request = try template(XAITTSAPI.synthesisRequest(
                text: textToken, apiKey: keyToken,
                request: XAITTSRequest(
                    voiceID: voice.id, language: nil, codec: .wav, sampleRate: XAITTSAPI.defaultSampleRate
                )
            ))
            maxCharacters = XAITTSAPI.maximumTextCharacters
        case .cartesia:
            let selection = CartesiaTTSRequest(
                voiceID: voice.id, outputFormat: .wav(sampleRate: sampleRate), languageIdentifier: nil
            )
            request = try template(
                CartesiaTTSAPI.synthesisRequest(transcript: textToken, apiKey: keyToken, request: selection),
                languageField: "language"
            )
            maxCharacters = TTSTextChunker.maximumChunkCharacters
        case .soniox(let resolved):
            guard let builtIn = SonioxTTSCatalog.voice(forID: resolved.providerVoiceID) else { return nil }
            let selection = SonioxTTSRequest(
                language: SonioxTTSCatalog.defaultLanguageCode, voice: builtIn, audioFormat: .wav,
                sampleRate: sampleRate
            )
            request = try template(
                SonioxTTSAPI.synthesisRequest(
                    text: textToken, apiKey: keyToken, request: selection, region: .unitedStates
                ),
                languageField: "language"
            )
            maxCharacters = SonioxTTSAPI.maxTextLength
        case .gemini(_, let model):
            request = try template(GeminiTTSAPI.synthesisRequest(
                input: textToken, apiKey: keyToken,
                request: GeminiTTSRequest(model: model, voiceID: voice.id, languageIdentifier: nil)
            ))
            maxCharacters = GeminiTTSAPI.maxInputCharacters
            response = "geminiInteraction"
        case .groq:
            request = try template(GroqTTSAPI.synthesisRequest(
                input: textToken, apiKey: keyToken, request: GroqTTSRequest(voiceID: voice.id)
            ))
            maxCharacters = GroqTTSAPI.maxInputCharacters
            maxSegments = GroqTTSAPI.maxRequestsPerSynthesis
        case .speechmatics:
            request = try template(SpeechmaticsTTSAPI.synthesisRequest(
                text: textToken, apiKey: keyToken, request: SpeechmaticsTTSRequest(voiceID: voice.id)
            ))
        case .elevenlabs(let model, let preset):
            let dialogueOnly = ElevenLabsTTSModels.dialogueOnlyModelIDs.contains(model.id)
            let effective = dialogueOnly ? ElevenLabsTTSModels.dialogueFallback : model
            request = try template(ElevenLabsTTSAPI.speechRequest(
                text: textToken, voiceID: preset.id, modelID: effective.id, apiKey: keyToken, format: .wav24k
            ))
            maxCharacters = effective.maximumCharacters
            maxSegments = 60
            if dialogueOnly {
                dialogue = try Dialogue(
                    maxCharacters: ElevenLabsTTSModels.dialogueCharacterLimit,
                    request: template(ElevenLabsTTSAPI.dialogueRequest(
                        text: textToken, voiceID: preset.id, modelID: model.id, apiKey: keyToken, format: .wav24k
                    )),
                    fallbackStatuses: dialogueFallbackStatuses
                )
            }
        case .mistral, .openai, .openaiRealtime:
            return nil
        }
        return Voice(
            key: "\(voice.modelID)|\(voice.id)", id: voice.id, name: voice.name, label: voice.label,
            provider: provider.id, providerName: provider.name, modelID: voice.modelID,
            credentialID: voice.apiKeyIdentifier, sampleRate: sampleRate, maxCharacters: maxCharacters,
            maxSegments: maxSegments, response: response, request: request, dialogue: dialogue
        )
    }

    enum ExportError: Error, Equatable {
        case unsupportedRequest(String)
    }

    /// The request with its tokens replaced by placeholders. `languageField` names a top-level body
    /// field Android fills with the phone's language, which is what Automatic resolves to wherever
    /// the text's language cannot be detected.
    static func template(_ request: URLRequest, xml: Bool = false, languageField: String? = nil) throws -> Template {
        guard let method = request.httpMethod, let url = request.url?.absoluteString,
              let body = request.httpBody else {
            throw ExportError.unsupportedRequest(request.url?.absoluteString ?? "")
        }
        let headers = (request.allHTTPHeaderFields ?? [:]).mapValues(placeholders)
        if xml {
            guard let text = String(data: body, encoding: .utf8), text.contains(textToken) else {
                throw ExportError.unsupportedRequest(url)
            }
            return Template(
                method: method, url: placeholders(url), headers: headers, jsonBody: nil, xmlBody: placeholders(text)
            )
        }
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: body)
        guard case .object(var fields) = decoded.storage else { throw ExportError.unsupportedRequest(url) }
        if let languageField {
            guard fields[languageField] != nil else { throw ExportError.unsupportedRequest(url) }
            fields[languageField] = .string(languagePlaceholder)
        }
        let json = substituted(.object(fields))
        let encoded = try String(bytes: JSONEncoder().encode(AnyCodable(json)), encoding: .utf8)
        guard encoded?.contains(textPlaceholder) == true else { throw ExportError.unsupportedRequest(url) }
        return Template(
            method: method, url: placeholders(url), headers: headers, jsonBody: AnyCodable(json), xmlBody: nil
        )
    }

    static func placeholders(_ value: String) -> String {
        value.replacingOccurrences(of: textToken, with: textPlaceholder)
            .replacingOccurrences(of: keyToken, with: keyPlaceholder)
            .replacingOccurrences(of: regionToken, with: regionPlaceholder)
            .replacingOccurrences(of: voiceToken, with: voicePlaceholder)
            .replacingOccurrences(of: voiceToken.lowercased(), with: voicePlaceholder)
            .replacingOccurrences(of: nameToken, with: namePlaceholder)
    }

    static func substituted(_ value: AnyCodable.JSONValue) -> AnyCodable.JSONValue {
        switch value {
        case .string(let text): .string(placeholders(text))
        case .array(let items): .array(items.map(substituted))
        case .object(let fields): .object(fields.mapValues(substituted))
        case .null, .bool, .int, .double: value
        }
    }
}
