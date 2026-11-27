import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Complete bounded lossless synthesis for the routes desktop hosts execute.
/// It owns no settings, files or playback. The caller captures all options.
public struct DesktopSpeechSynthesis: Sendable {
    public static let maximumSSMLBytes = 65_536
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice,
        options: VoiceSynthesisOptions, credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try await synthesize(source, voice: voice, options: options, xaiInventory: nil, credential: credential)
    }

    public func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice,
        options: VoiceSynthesisOptions, xaiInventory: XAIAccountVoiceInventory?,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try await synthesize(source, voice: voice, options: options,
                             accountInventory: xaiInventory.map(VoiceAccountInventory.xai), credential: credential)
    }

    public func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice,
        options: VoiceSynthesisOptions, accountInventory: VoiceAccountInventory?,
        sonioxRegion: SonioxTTSRegion = .unitedStates, language: String? = nil,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try await execute(
            SynthesisInvocation(
                source: source,
                voice: voice,
                options: options,
                accountInventory: accountInventory,
                sonioxRegion: sonioxRegion,
                language: language,
                studioConfiguration: nil
            ),
            credential: credential
        )
    }

    public func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try await execute(
            SynthesisInvocation(
                source: source,
                voice: selection.voice,
                options: selection.options,
                accountInventory: selection.accountInventory,
                sonioxRegion: selection.sonioxRegion,
                language: selection.language,
                studioConfiguration: selection.studioConfiguration
            ),
            credential: credential
        )
    }

    private struct SynthesisInvocation {
        let source: VoiceOutputSourceSnapshot
        let voice: DesktopSpeechVoice
        let options: VoiceSynthesisOptions
        let accountInventory: VoiceAccountInventory?
        let sonioxRegion: SonioxTTSRegion
        let language: String?
        let studioConfiguration: VoiceStudioConfiguration?
    }

    private func validatedVoice(for invocation: SynthesisInvocation) throws -> DesktopSpeechVoice {
        let voice = try invocation.voice.applyingQuality(invocation.options.quality)
        if case .studio(let studioVoice) = voice {
            guard let config = invocation.studioConfiguration, config.enabled else {
                throw VoiceStudioError.disabled
            }
            guard config.kind == studioVoice.studioKind else {
                throw VoiceSynthesisConfigurationError.unsupportedVoice
            }
        } else {
            let isKnown = DesktopSpeechVoice.voices.contains(voice)
                || invocation.accountInventory?.contains(voice) == true
            guard isKnown else { throw VoiceSynthesisConfigurationError.unsupportedVoice }
        }
        try invocation.options.validate(for: voice.capabilities)
        return voice
    }

    // exhaustive provider dispatch across the existing voice catalogue; no behavior change.
    // swiftlint:disable:next cyclomatic_complexity
    private func execute(
        _ invocation: SynthesisInvocation,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try Task.checkCancellation()
        let voice = try validatedVoice(for: invocation)
        let source = invocation.source
        let options = invocation.options
        switch voice {
        case .deepgram(let deepgramVoice):
            let rate = DesktopSpeechVoice.deepgram(deepgramVoice).sampleRate(quality: options.quality)
            return try await DeepgramSpeechExport(session: session).synthesize(
                source, voice: deepgramVoice, sampleRate: rate, credential: credential)
        case .azureNeural, .azureMAI:
            return try await synthesizeAzure(source.text, voice: voice, options: options, credential: credential)
        case .xai:
            return try await DesktopXAISpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: options,
                inventory: invocation.accountInventory?.xai, credential: credential)
        case .cartesia:
            return try await DesktopCartesiaSpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: options, credential: credential)
        case .mistral:
            return try await DesktopMistralSpeechSynthesis(session: session).synthesize(
                source, voice: voice, inventory: invocation.accountInventory, credential: credential)
        case .soniox:
            let selection = try DesktopSpeechSelection(
                voice: voice, options: options, accountInventory: invocation.accountInventory,
                sonioxRegion: invocation.sonioxRegion, language: invocation.language)
            return try await DesktopSonioxSpeechSynthesis(session: session).synthesize(
                source, selection: selection, credential: credential)
        case .gemini:
            return try await DesktopGeminiSpeechSynthesis(session: session).synthesize(
                source, voice: voice, language: invocation.language, credential: credential)
        case .groq:
            return try await DesktopGroqSpeechSynthesis(session: session).synthesize(
                source, voice: voice, credential: credential)
        case .speechmatics:
            return try await DesktopSpeechmaticsSpeechSynthesis(session: session).synthesize(
                source, voice: voice, credential: credential)
        case .openai:
            return try await DesktopOpenAISpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: options, credential: credential)
        case .openaiRealtime(let voiceID):
            return try await DesktopOpenAISpeechSynthesis(session: session).synthesizeRealtime(
                source, voice: voice, voiceID: voiceID, options: options, credential: credential)
        case .elevenlabs:
            return try await DesktopElevenLabsSpeechSynthesis(session: session).synthesize(
                source, voice: voice, credential: credential)
        case .studio(let studioVoice):
            return try await DesktopVoiceStudioSpeechSynthesis(session: session).synthesize(
                source, voice: studioVoice, configuration: invocation.studioConfiguration,
                language: invocation.language, credential: credential)
        }
    }

    /// Preflights the same final Azure body the transport sends, before key
    /// access. This does not validate XML or resolve credentials/endpoints.
    public static func validateSSMLInput(
        _ text: String, voice: DesktopSpeechVoice, options: VoiceSynthesisOptions
    ) throws {
        guard options.useSSML else { return }
        try options.validate(for: voice.capabilities)
        switch voice {
        case .azureNeural, .azureMAI: break
        default: throw VoiceSynthesisConfigurationError.unsupportedControls
        }
        let isDocument = options.useSSML && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<speak")
        if isDocument && (options.speed != 1 || options.pitch != 0) {
            throw DesktopSpeechSynthesisError.documentControls
        }
        if text.utf8.count > Self.maximumSSMLBytes {
            throw DesktopSpeechSynthesisError.ssmlTooLarge
        }
        let body = try AzureSpeechVoiceAPI.ssmlBody(
            text: text, voice: voice.id, speed: options.speed, pitch: options.pitch, useSSML: true)
        guard body.utf8.count <= Self.maximumSSMLBytes else { throw DesktopSpeechSynthesisError.ssmlTooLarge }
    }

    private func synthesizeAzure(
        _ text: String, voice: DesktopSpeechVoice, options: VoiceSynthesisOptions,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try Self.validateSSMLInput(text, voice: voice, options: options)
        // Never split XML through a tag or lose a document's prosody.
        let segments = options.useSSML ? [text] : SpeechTextSegmenter.segments(text)
        let supplied = try await credential()
        try Task.checkCancellation()
        let sampleRate = voice.sampleRate(quality: options.quality)
        return try await DesktopSpeechHTTP.joinedWAV(segments, sampleRate: sampleRate) { segment in
            try await azureSegment(segment, voice: voice, options: options, credential: supplied)
        }
    }

    private func azureSegment(
        _ text: String, voice: DesktopSpeechVoice, options: VoiceSynthesisOptions, credential: String
    ) async throws -> DeepgramSpeechAudio {
        try Task.checkCancellation()
        let sampleRate = voice.sampleRate(quality: options.quality)
        let request = try AzureSpeechVoiceAPI.synthesisRequest(
            credentials: credential, text: text, voice: voice.id, format: "riff-\(sampleRate / 1000)khz-16bit-mono-pcm",
            speed: options.speed, pitch: options.pitch, useSSML: options.useSSML
        )
        guard let body = request.httpBody, body.count <= Self.maximumSSMLBytes else {
            throw DesktopSpeechSynthesisError.ssmlTooLarge
        }
        return try await DesktopSpeechHTTP.measuredSegment(
            sampleRate: sampleRate,
            begin: {
                $0.begin(voice: voice, inputCharacters: text.unicodeScalars.count, usesSSML: options.useSSML)
            },
            receive: {
                try await DesktopSpeechHTTP.receive(request, session: session) { http in
                    guard http.statusCode == 200 else { throw AzureSpeechError.service(http.statusCode) }
                }
            }
        )
    }
}

public enum DesktopSpeechSynthesisError: LocalizedError, Equatable {
    case documentControls, ssmlTooLarge, invalidAudio, audioTooLarge, timedOut, transportFailure

    public var errorDescription: String? {
        switch self {
        case .documentControls:
            "A complete SSML document defines its own prosody. Use normal sliders or an SSML fragment."
        case .ssmlTooLarge:
            "The complete SSML request exceeds 64 KiB. Shorten it or use plain text for segmented speech."
        case .invalidAudio:
            "The speech provider returned empty, silent, truncated or unsupported audio."
        case .audioTooLarge:
            "Generated speech exceeds the 64 MiB audio limit."
        case .timedOut:
            "The speech provider did not finish within the synthesis deadline."
        case .transportFailure:
            "The speech provider could not be reached."
        }
    }
}
