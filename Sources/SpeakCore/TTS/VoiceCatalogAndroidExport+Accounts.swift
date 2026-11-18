import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Account-discovered voices and OpenAI Realtime, built with the same SpeakCore request builders
/// and discovery limits the desktop host uses (`MistralAccountVoiceInventory`,
/// `XAIAccountVoiceInventory`, `SonioxAccountVoiceInventory` and `OpenAIRealtimeSpeechSynthesizer`).
extension VoiceCatalogAndroidExport {
    /// A bodyless listing request; `pageParameter` is the query item later pages add: `offset`
    /// (a multiple of `pageSize`), or a cursor query item (`cursor` with Soniox's `next_page_cursor`,
    /// `pagination_token` with xAI's). A status in `absentStatuses` means the account has no such
    /// library, so the listing ends with what it has rather than failing.
    struct ListRequest: Encodable, Equatable {
        let method: String
        let url: String
        let headers: [String: String]
        let pageParameter: String?
        let pageSize: Int?
        let maxPages: Int
        let maxResponseBytes: Int
        let timeoutSeconds: Int
        let absentStatuses: [Int]
    }

    /// A provider whose voices come from the user's account. `listing` names the response shape
    /// (`mistral`, `xai` or `soniox`); `fixedVoiceIDs` are documented presets, which a listing
    /// never offers as account voices.
    struct AccountProvider: Encodable, Equatable {
        let provider: String
        let providerName: String
        let listing: String
        let modelID: String
        let credentialID: String
        /// Built from `{voice}`, a listed voice's API identifier, and `{name}`, its display name.
        let keyTemplate: String
        let idTemplate: String
        let labelTemplate: String
        /// The request sends the API identifier lowercased, as SpeakCore's builder does.
        let lowercaseVoiceID: Bool
        let fixedVoiceIDs: [String]
        /// Soniox: only clones whose status for this model is `ready` can speak.
        let readyModel: String?
        let maxVoices: Int
        /// xAI: the single-page built-in listing, read before `list`. Its voices that are not
        /// `fixedVoiceIDs` join the account's, and `maxVoices` and duplicate checks span both listings.
        let builtInList: ListRequest?
        let list: ListRequest
        let sampleRate: Int
        let maxCharacters: Int
        let maxSegments: Int?
        /// `wav`, or `base64Wav` for a JSON body whose `audioField` holds base64 WAV.
        let response: String
        let audioField: String?
        let request: Template
    }

    struct RealtimeVoice: Encodable, Equatable {
        let key: String
        let id: String
        let name: String
        let label: String
        let voice: String
    }

    /// One WebSocket per reading: send `sessionUpdate` (`{voice}`), wait for `session.updated`, then
    /// for each chunk of at most `chunkCharacters` send `responseCreate` (`{text}`) and keep its audio
    /// only when the transcript is a verbatim reading, as `RealtimeReadingCheck` decides: a numeral
    /// may take up to `spokenWordsPerNumeral` words and each symbol `spokenWordsPerSymbol`.
    struct Realtime: Encodable, Equatable {
        let provider: String
        let providerName: String
        let displayName: String
        let modelID: String
        let credentialID: String
        let url: String
        let headers: [String: String]
        let sessionUpdate: AnyCodable
        let responseCreate: AnyCodable
        let sampleRate: Int
        let chunkCharacters: Int
        let spokenWordsPerNumeral: Int
        let spokenWordsPerSymbol: Int
        let responseTimeoutSeconds: Int
        let voices: [RealtimeVoice]
    }

    /// Listing deadline of every desktop account inventory.
    static let accountListingTimeoutSeconds = 20
    /// `OpenAIRealtimeSpeechSynthesizer`'s default deadline, applied to each response on Android.
    static let realtimeResponseTimeoutSeconds = 120

    static func accountProviders() throws -> [AccountProvider] {
        try [mistralAccount(), xaiAccount(), sonioxAccount()]
    }

    private static func mistralAccount() throws -> AccountProvider {
        let voice = DesktopSpeechVoice.mistral(MistralTTSVoice(id: voiceToken, name: nameToken))
        let request = try template(MistralTTSAPI.synthesisRequest(
            input: textToken, apiKey: keyToken, request: MistralTTSRequest(voiceID: voiceToken, responseFormat: .wav)
        ))
        return try account(
            voice, provider: .mistral, request: request,
            list: listRequest(
                MistralTTSAPI.voiceListRequest(apiKey: keyToken), pageParameter: "offset",
                pageSize: MistralTTSAPI.voicePageSize, maxPages: MistralTTSAPI.maxVoicePages,
                maxResponseBytes: MistralAccountVoiceInventory.maximumPageBytes
            ),
            fixedVoiceIDs: [], readyModel: nil, maxVoices: MistralAccountVoiceInventory.maximumVoices,
            maxCharacters: MistralTTSAPI.maxInputCharacters,
            response: "base64Wav", audioField: MistralTTSAPI.audioDataField
        )
    }

    private static func xaiAccount() throws -> AccountProvider {
        let voice = DesktopSpeechVoice.xai(XAITTSVoice(id: voiceToken, name: nameToken))
        let request = try template(XAITTSAPI.synthesisRequest(
            text: textToken, apiKey: keyToken,
            request: XAITTSRequest(
                voiceID: voiceToken, language: nil, codec: .wav, sampleRate: XAITTSAPI.defaultSampleRate
            )
        ))
        return try account(
            voice, provider: .xai, request: request,
            // Built-ins beyond the fixed presets are listed here; the team's clones come from custom voices.
            builtInList: listRequest(
                XAITTSAPI.voiceListRequest(apiKey: keyToken), pageParameter: nil, pageSize: nil, maxPages: 1,
                maxResponseBytes: XAIAccountVoiceInventory.maximumResponseBytes
            ),
            list: listRequest(
                XAITTSAPI.customVoiceListRequest(apiKey: keyToken, paginationToken: nil),
                pageParameter: "pagination_token", pageSize: XAITTSAPI.customVoicePageSize,
                maxPages: XAITTSAPI.maximumCustomVoicePages,
                maxResponseBytes: XAIAccountVoiceInventory.maximumResponseBytes,
                absentStatuses: XAITTSAPI.customVoicesUnavailableStatuses.sorted()
            ),
            fixedVoiceIDs: XAITTSCatalog.voices.map(\.apiVoiceID), readyModel: nil,
            maxVoices: XAIAccountVoiceInventory.maximumVoices, maxCharacters: XAITTSAPI.maximumTextCharacters
        )
    }

    private static func sonioxAccount() throws -> AccountProvider {
        let clone = SonioxTTSAccountVoice(id: voiceToken, name: nameToken, filename: nil, models: [])
        let voice = DesktopSpeechVoice.soniox(SonioxTTSResolvedVoice(
            apiVoiceID: clone.id, providerVoiceID: clone.providerVoiceID, displayName: clone.name,
            accountVoice: clone, fallbackReason: nil
        ))
        let request = try template(
            SonioxTTSAPI.synthesisRequest(
                text: textToken, apiKey: keyToken,
                request: SonioxTTSRequest(
                    language: SonioxTTSCatalog.defaultLanguageCode, accountVoice: clone, audioFormat: .wav,
                    sampleRate: voice.sampleRate(quality: nil)
                ),
                region: .unitedStates
            ),
            languageField: "language"
        )
        return try account(
            voice, provider: .soniox, request: request,
            list: listRequest(
                SonioxTTSAPI.voiceListRequest(apiKey: keyToken, region: .unitedStates), pageParameter: "cursor",
                pageSize: nil, maxPages: SonioxTTSAPI.maxVoicePages,
                maxResponseBytes: SonioxAccountVoiceInventory.maximumPageBytes
            ),
            fixedVoiceIDs: SonioxTTSCatalog.voices.map(\.apiVoiceName),
            readyModel: SonioxTTSCatalog.defaultModel.rawValue,
            maxVoices: SonioxAccountVoiceInventory.maximumVoices, maxCharacters: SonioxTTSAPI.maxTextLength
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func account(
        _ voice: DesktopSpeechVoice, provider: VoiceAccountProvider, request: Template,
        builtInList: ListRequest? = nil, list: ListRequest,
        fixedVoiceIDs: [String], readyModel: String?, maxVoices: Int, maxCharacters: Int,
        response: String = "wav", audioField: String? = nil
    ) throws -> AccountProvider {
        let encoded = try String(bytes: JSONEncoder().encode(request), encoding: .utf8) ?? ""
        guard encoded.contains(voicePlaceholder) else { throw ExportError.unsupportedRequest(request.url) }
        // A builder that lowercases the voice leaves the lowercased token, which `placeholders` also maps.
        let lowercased = try templateLowercasesVoice(provider)
        return AccountProvider(
            provider: provider.id, providerName: provider.displayName, listing: provider.id,
            modelID: voice.modelID, credentialID: voice.apiKeyIdentifier,
            keyTemplate: placeholders("\(voice.modelID)|\(voice.id)"), idTemplate: placeholders(voice.id),
            labelTemplate: placeholders(voice.label), lowercaseVoiceID: lowercased, fixedVoiceIDs: fixedVoiceIDs,
            readyModel: readyModel, maxVoices: maxVoices, builtInList: builtInList, list: list,
            sampleRate: voice.sampleRate(quality: nil), maxCharacters: maxCharacters, maxSegments: nil,
            response: response, audioField: audioField, request: request
        )
    }

    /// Whether the provider's request builder sends the voice identifier lowercased.
    private static func templateLowercasesVoice(_ provider: VoiceAccountProvider) throws -> Bool {
        let body: Data?
        switch provider {
        case .xai:
            body = try XAITTSAPI.synthesisRequest(
                text: textToken, apiKey: keyToken, request: XAITTSRequest(voiceID: voiceToken, language: nil)
            ).httpBody
        case .mistral:
            body = try MistralTTSAPI.synthesisRequest(
                input: textToken, apiKey: keyToken, request: MistralTTSRequest(voiceID: voiceToken)
            ).httpBody
        default:
            return false
        }
        let text = body.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        return !text.contains(voiceToken) && text.contains(voiceToken.lowercased())
    }

    static func listRequest(
        _ request: URLRequest, pageParameter: String?, pageSize: Int?, maxPages: Int, maxResponseBytes: Int,
        absentStatuses: [Int] = []
    ) throws -> ListRequest {
        guard let url = request.url?.absoluteString, request.httpBody == nil else {
            throw ExportError.unsupportedRequest(request.url?.absoluteString ?? "")
        }
        return ListRequest(
            method: request.httpMethod ?? "GET", url: placeholders(url),
            headers: (request.allHTTPHeaderFields ?? [:]).mapValues(placeholders),
            pageParameter: pageParameter, pageSize: pageSize, maxPages: maxPages,
            maxResponseBytes: maxResponseBytes, timeoutSeconds: accountListingTimeoutSeconds,
            absentStatuses: absentStatuses
        )
    }

    static func realtime() throws -> Realtime {
        guard let request = OpenAIRealtimeSpeech.webSocketRequest(apiKey: keyToken),
              let url = request.url?.absoluteString,
              let session = OpenAIRealtimeSpeech.sessionUpdateJSON(voice: voiceToken, speed: 1),
              let response = OpenAIRealtimeSpeech.responseCreateJSON(text: textToken) else {
            throw ExportError.unsupportedRequest("realtime")
        }
        let voices = OpenAIRealtimeSpeech.voices.map { entry in
            let voice = DesktopSpeechVoice.openaiRealtime(entry.id)
            return RealtimeVoice(
                key: "\(voice.modelID)|\(voice.id)", id: voice.id, name: voice.name, label: voice.label,
                voice: entry.id
            )
        }
        // Android keeps one OpenAI key, which SpeakCore accepts in place of the separate TTS key.
        let credentialID = "openai.apiKey"
        return try Realtime(
            provider: "openai", providerName: "OpenAI", displayName: OpenAIRealtimeSpeech.displayName,
            modelID: OpenAIRealtimeSpeech.catalogID, credentialID: credentialID,
            url: placeholders(url), headers: (request.allHTTPHeaderFields ?? [:]).mapValues(placeholders),
            sessionUpdate: realtimeFrame(session), responseCreate: realtimeFrame(response),
            sampleRate: OpenAIRealtimeSpeech.sampleRate, chunkCharacters: OpenAIRealtimeSpeech.chunkCharacters,
            spokenWordsPerNumeral: RealtimeReadingCheck.maximumNumeralWords,
            spokenWordsPerSymbol: RealtimeReadingCheck.wordsPerSymbol,
            responseTimeoutSeconds: realtimeResponseTimeoutSeconds, voices: voices
        )
    }

    private static func realtimeFrame(_ json: String) throws -> AnyCodable {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        return AnyCodable(substituted(decoded.storage))
    }
}
