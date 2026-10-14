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
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try Task.checkCancellation()
        guard DesktopSpeechVoice.voices.contains(voice) || accountInventory?.contains(voice) == true else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        try options.validate(for: voice.capabilities)
        switch voice {
        case .deepgram(let voice):
            return try await DeepgramSpeechExport(session: session).synthesize(
                source, voice: voice, credential: credential
            )
        case .azureNeural, .azureMAI:
            return try await synthesizeAzure(source.text, voice: voice, options: options, credential: credential)
        case .xai:
            return try await DesktopXAISpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: options, inventory: accountInventory?.xai, credential: credential)
        case .cartesia:
            return try await DesktopCartesiaSpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: options, credential: credential)
        case .gemini:
            return try await DesktopGeminiSpeechSynthesis(session: session).synthesize(
                source, voice: voice, credential: credential)
        case .groq:
            return try await DesktopGroqSpeechSynthesis(session: session).synthesize(
                source, voice: voice, credential: credential)
        case .speechmatics:
            return try await DesktopSpeechmaticsSpeechSynthesis(session: session).synthesize(
                source, voice: voice, credential: credential)
        case .openai:
            return try await DesktopOpenAISpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: options, credential: credential)
        case .mistral:
            return try await DesktopMistralSpeechSynthesis(session: session).synthesize(
                source, voice: voice, inventory: accountInventory, credential: credential)
        }
    }

    private func synthesizeAzure(
        _ text: String, voice: DesktopSpeechVoice, options: VoiceSynthesisOptions,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let isDocument = options.useSSML && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<speak")
        if isDocument && (options.speed != 1 || options.pitch != 0) {
            throw DesktopSpeechSynthesisError.documentControls
        }
        if options.useSSML && text.utf8.count > Self.maximumSSMLBytes {
            throw DesktopSpeechSynthesisError.ssmlTooLarge
        }
        // Never split XML through a tag or lose a document's prosody.
        let segments = options.useSSML ? [text] : SpeechTextSegmenter.segments(text)
        let supplied = try await credential()
        try Task.checkCancellation()
        var pcm = Data()
        for segment in segments {
            let audio = try await azureSegment(segment, voice: voice, options: options, credential: supplied)
            let payload = audio.wav.dropFirst(44)
            guard payload.count <= DeepgramSpeechExport.maximumPCMBytes - pcm.count else {
                throw DesktopSpeechSynthesisError.audioTooLarge
            }
            pcm.append(contentsOf: payload)
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        return wav
    }

    private func azureSegment(
        _ text: String, voice: DesktopSpeechVoice, options: VoiceSynthesisOptions, credential: String
    ) async throws -> DeepgramSpeechAudio {
        try Task.checkCancellation()
        let request = try AzureSpeechVoiceAPI.synthesisRequest(
            credentials: credential, text: text, voice: voice.id, format: "riff-24khz-16bit-mono-pcm",
            speed: options.speed, pitch: options.pitch, useSSML: options.useSSML
        )
        guard let body = request.httpBody, body.count <= Self.maximumSSMLBytes else {
            throw DesktopSpeechSynthesisError.ssmlTooLarge
        }
        let capture = VoiceSynthesisUsage.capture
        let id = capture?.begin(voice: voice, inputCharacters: text.unicodeScalars.count, usesSSML: options.useSSML)
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do { audio = try DeepgramSpeechWAV.canonical(received, sampleRate: 24_000) } catch {
                throw DesktopSpeechSynthesisError.invalidAudio
            }
            if let id { capture?.finish(id, outcome: .completed, audioDuration: audio.duration) }
            return audio
        } catch {
            if let id { capture?.finish(id, outcome: error is CancellationError ? .cancelled : .failed) }
            throw error
        }
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        do {
            return try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120)
            ) { http in
                guard http.statusCode == 200 else { throw AzureSpeechError.service(http.statusCode) }
            }.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let service = error as? AzureSpeechError { throw service }
            switch error as? OpenRouterBoundedResponseTransport.Failure {
            case .responseTooLarge: throw DesktopSpeechSynthesisError.audioTooLarge
            case .timedOut: throw DesktopSpeechSynthesisError.timedOut
            case .invalidResponse: throw DesktopSpeechSynthesisError.invalidAudio
            case nil:
                throw (error as? URLError)?.code == .timedOut
                    ? DesktopSpeechSynthesisError.timedOut : DesktopSpeechSynthesisError.transportFailure
            }
        }
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
