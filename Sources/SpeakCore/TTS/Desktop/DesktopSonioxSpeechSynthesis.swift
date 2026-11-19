import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopSonioxSpeechSynthesis: Sendable {
    let session: URLSession

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        guard case .soniox(let voice) = selection.voice else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        let segments = TTSTextChunker.chunks(source.text, maximumCharacters: SonioxTTSAPI.maxTextLength)
        guard !segments.isEmpty else { throw DesktopSpeechSynthesisError.invalidAudio }
        let key = try VoiceOutputCredentialSlot(provider: .soniox).validatedKey(await credential())
        try Task.checkCancellation()
        if voice.accountVoice != nil {
            guard let inventory = selection.accountInventory?.soniox, inventory.region == selection.sonioxRegion,
                  inventory.desktopVoices.contains(selection.voice), inventory.matchesCredential(key) else {
                throw VoiceAccountDiscoveryError.credentialChanged(.soniox)
            }
        }
        let request = try request(for: voice, selection: selection, text: source.text)
        let end = ContinuousClock.now.advanced(by: .seconds(120))
        return try await DesktopSpeechHTTP.joinedWAV(segments, sampleRate: selection.sampleRate) { segment in
            try await synthesizeSegment(segment, key: key, request: request, selection: selection, end: end)
        }
    }

    private func request(
        for voice: SonioxTTSResolvedVoice, selection: DesktopSpeechSelection, text: String
    ) throws -> SonioxTTSRequest {
        let language = SonioxTTSCatalog.languageCode(forVoiceOutputIdentifier: selection.language, content: text)
        if let account = voice.accountVoice {
            return .init(language: language, accountVoice: account, audioFormat: .wav,
                         sampleRate: selection.sampleRate, speed: selection.options.speed)
        }
        guard let builtIn = SonioxTTSCatalog.voice(forID: voice.providerVoiceID) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        return .init(language: language, voice: builtIn, audioFormat: .wav,
                     sampleRate: selection.sampleRate, speed: selection.options.speed)
    }

    private func synthesizeSegment(
        _ text: String, key: String, request: SonioxTTSRequest, selection: DesktopSpeechSelection,
        end: ContinuousClock.Instant
    ) async throws -> DeepgramSpeechAudio {
        var urlRequest = try SonioxTTSAPI.synthesisRequest(
            text: text, apiKey: key, request: request, region: selection.sonioxRegion)
        urlRequest.timeoutInterval = 120
        return try await DesktopSpeechHTTP.measuredSegment(
            sampleRate: selection.sampleRate, requireComplete: true,
            begin: {
                $0.begin(voice: selection.voice, inputCharacters: text.unicodeScalars.count, usesSSML: false,
                         pricingCharacters: text.count, accountInventory: selection.accountInventory)
            },
            receive: { try await receive(urlRequest, end: end) }
        )
    }

    private func receive(_ request: URLRequest, end: ContinuousClock.Instant) async throws -> Data {
        do {
            let remaining = ContinuousClock.now.duration(to: end)
            guard remaining > .zero else { throw DesktopSpeechSynthesisError.timedOut }
            let received = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechExport.maximumPCMBytes, deadline: remaining)
            guard (200..<300).contains(received.http.statusCode) else {
                throw serviceFailure(received.body, statusCode: received.http.statusCode)
            }
            return received.body
        } catch {
            if DesktopSpeechHTTP.isCancellation(error) { throw CancellationError() }
            if error is DesktopSonioxSpeechError || error is DesktopSpeechSynthesisError { throw error }
            throw DesktopSpeechHTTP.transportError(error)
        }
    }

    private func serviceFailure(_ body: Data, statusCode: Int) -> DesktopSonioxSpeechError {
        let failure = SonioxTTSAPI.failure(from: body, statusCode: statusCode)
        let classification: SonioxTTSFailureType
        if case .unknown = failure.type { classification = .unknown("unknown") } else {
            classification = failure.type
        }
        return .service(failure.statusCode, classification)
    }
}

public enum DesktopSonioxSpeechError: LocalizedError, Equatable {
    case unsupportedRegion
    case unsupportedLanguage
    case service(Int, SonioxTTSFailureType)

    public var errorDescription: String? {
        switch self {
        case .unsupportedRegion:
            "The stored Soniox region is unavailable. Choose a processing region and its matching project key."
        case .unsupportedLanguage:
            "The stored Voice language is unavailable. Choose automatic or a supported Voice language locale."
        case .service(401, _), .service(403, _), .service(_, .unauthenticated):
            "Soniox rejected the saved key. Check the project key and selected processing region."
        case .service(_, .voiceNotFound), .service(_, .voiceNotReady):
            "The Soniox clone is deleted or not ready for v2. " +
                "Refresh account voices and explicitly choose a ready voice."
        case .service(429, _), .service(_, .rateLimited):
            "Soniox speech is rate limited. Try again later."
        case .service(let status, _):
            "Soniox speech failed (HTTP \(status)). No partial audio was published."
        }
    }
}
