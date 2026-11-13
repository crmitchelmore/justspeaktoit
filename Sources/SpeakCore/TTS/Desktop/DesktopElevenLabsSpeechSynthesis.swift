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
        return try await DesktopSpeechHTTP.joinedWAV(plans, sampleRate: ElevenLabsTTSAPI.sampleRate) { plan in
            do {
                return try await segment(plan, voice: preset, key: key)
            } catch ElevenLabsTTSAPIError.service(let status)
                where plan.dialogue && ElevenLabsTTSAPI.permitsDialogueFallback(status: status) {
                try Task.checkCancellation()
                return try await segment(
                    Plan(text: plan.text, model: ElevenLabsTTSModels.dialogueFallback, dialogue: false),
                    voice: preset, key: key)
            }
        }
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
        return try await DesktopSpeechHTTP.measuredSegment(
            sampleRate: ElevenLabsTTSAPI.sampleRate, requireComplete: true,
            begin: {
                $0.begin(voice: .elevenlabs(plan.model, voice), inputCharacters: plan.text.unicodeScalars.count,
                         usesSSML: false, pricingCharacters: plan.text.count)
            },
            receive: { try await receive(request) }
        )
    }

    private func receive(_ request: URLRequest) async throws -> Data {
        try await DesktopSpeechHTTP.receive(request, session: session) { response in
            guard response.statusCode == 200 else { throw ElevenLabsTTSAPIError.service(response.statusCode) }
        }
    }
}
