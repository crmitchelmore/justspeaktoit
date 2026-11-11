import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopElevenLabsSpeechSynthesis: Sendable {
    let session: URLSession
    private struct Plan: Sendable {
        let text: String
        let model: ElevenLabsTTSModels.Model
        let dialogue: Bool
    }

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, voice: DesktopSpeechVoice,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        guard case .elevenlabs(let model, let preset) = voice,
              ElevenLabsTTSModels.all.contains(model), ElevenLabsTTSCatalog.voices.contains(preset) else {
            throw VoiceSynthesisConfigurationError.unsupportedVoice
        }
        let plans = try Self.plans(text: source.text, model: model, voice: preset)
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw ElevenLabsTTSAPIError.missingCredential }
        guard key.utf8.count <= 8_192,
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ElevenLabsTTSAPIError.invalidCredential
        }
        var pcm = Data()
        for plan in plans {
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do {
                audio = try await segment(plan, voice: preset, key: key)
            } catch ElevenLabsTTSAPIError.service(let status)
                where plan.dialogue && ElevenLabsTTSAPI.permitsDialogueFallback(status: status) {
                try Task.checkCancellation()
                audio = try await segment(
                    Plan(text: plan.text, model: ElevenLabsTTSModels.dialogueFallback, dialogue: false),
                    voice: preset, key: key)
            }
            let payload = audio.wav.dropFirst(44)
            guard payload.count <= DeepgramSpeechExport.maximumPCMBytes - pcm.count else {
                throw DesktopSpeechSynthesisError.audioTooLarge
            }
            pcm.append(contentsOf: payload)
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: ElevenLabsTTSAPI.sampleRate) else {
            throw DesktopSpeechSynthesisError.invalidAudio
        }
        return wav
    }

    private static func plans(
        text: String, model: ElevenLabsTTSModels.Model, voice: ElevenLabsTTSVoice
    ) throws -> [Plan] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ElevenLabsTTSAPIError.emptyText
        }
        let dialogueOnly = ElevenLabsTTSModels.dialogueOnlyModelIDs.contains(model.id)
        let dialogue = dialogueOnly && text.count <= ElevenLabsTTSModels.dialogueCharacterLimit
        let effective = dialogueOnly && !dialogue ? ElevenLabsTTSModels.dialogueFallback : model
        // Decide long-dialogue fallback before segmentation, as the Mac does.
        let texts = dialogue ? [text] : SpeechTextSegmenter.segments(text, limit: effective.maximumCharacters)
        guard !texts.isEmpty, texts.count <= 60 else { throw ElevenLabsTTSAPIError.inputTooLarge }
        let plans = texts.map { Plan(text: $0, model: effective, dialogue: dialogue) }
        for plan in plans {
            try validate(plan, voice: voice)
            if dialogue {
                try validate(Plan(text: plan.text, model: ElevenLabsTTSModels.dialogueFallback, dialogue: false),
                             voice: voice)
            }
        }
        return plans
    }

    static func pricingCharacterCount(
        text: String, model: ElevenLabsTTSModels.Model, voice: ElevenLabsTTSVoice
    ) throws -> Int {
        try plans(text: text, model: model, voice: voice).reduce(0) { $0 + $1.text.count }
    }

    private static func validate(_ plan: Plan, voice: ElevenLabsTTSVoice) throws {
        guard plan.text.count <= plan.model.maximumCharacters else { throw ElevenLabsTTSAPIError.inputTooLarge }
        let request = try request(plan, voice: voice, key: "synthetic-preflight")
        guard let body = request.httpBody, body.count <= ElevenLabsTTSAPI.maximumRequestBytes else {
            throw ElevenLabsTTSAPIError.inputTooLarge
        }
    }

    private static func request(_ plan: Plan, voice: ElevenLabsTTSVoice, key: String) throws -> URLRequest {
        if plan.dialogue {
            return try ElevenLabsTTSAPI.dialogueRequest(
                text: plan.text, voiceID: voice.id, modelID: plan.model.id, apiKey: key, format: .wav24k)
        }
        return try ElevenLabsTTSAPI.speechRequest(
            text: plan.text, voiceID: voice.id, modelID: plan.model.id, apiKey: key, format: .wav24k)
    }

    private func segment(_ plan: Plan, voice: ElevenLabsTTSVoice, key: String) async throws -> DeepgramSpeechAudio {
        try Task.checkCancellation()
        let request = try Self.request(plan, voice: voice, key: key)
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(voice: .elevenlabs(plan.model, voice),
                                    inputCharacters: plan.text.unicodeScalars.count,
                                    usesSSML: false, pricingCharacters: plan.text.count)
        do {
            let received = try await receive(request)
            try Task.checkCancellation()
            let audio: DeepgramSpeechAudio
            do {
                audio = try DeepgramSpeechWAV.canonical(
                    received, sampleRate: ElevenLabsTTSAPI.sampleRate, requireComplete: true)
            } catch { throw DesktopSpeechSynthesisError.invalidAudio }
            if let ticket { capture?.finish(ticket, outcome: .completed, audioDuration: audio.duration) }
            return audio
        } catch {
            if let ticket { capture?.finish(ticket, outcome: error is CancellationError ? .cancelled : .failed) }
            throw error
        }
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        do {
            return try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: DeepgramSpeechSynthesizer.defaultResponseLimit,
                deadline: .seconds(120)
            ) { response in
                guard response.statusCode == 200 else { throw ElevenLabsTTSAPIError.service(response.statusCode) }
            }.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let service = error as? ElevenLabsTTSAPIError { throw service }
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
