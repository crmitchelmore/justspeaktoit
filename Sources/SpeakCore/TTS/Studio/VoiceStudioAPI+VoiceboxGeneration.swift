import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension VoiceStudioAPI {
    static func fetchVoiceboxGeneration(
        id: String,
        context: VoiceStudioRequestContext,
        deadline: ContinuousClock.Instant
    ) async throws -> VoiceStudioWAV.NormalizedAudio {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            throw VoiceStudioError.invalidResponse(kind: .voicebox, detail: "Invalid Voicebox generation ID.")
        }
        var status = makeRequest(
            url: context.endpoint.endpointURL(path: "generate/\(id)/status"),
            method: "GET", apiKey: context.apiKey, timeout: 180
        )
        status.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Voicebox closes the stream after the terminal event. The bounded transport
        // cancels the request at the synthesis deadline or when the caller cancels.
        let events = try await performValidated(
            status, context: context,
            budget: .init(limit: maxMetadataBytes, deadline: ContinuousClock.now.duration(to: deadline))
        )
        guard let last = String(decoding: events.body, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("data:") }),
            let event = try? JSONDecoder().decode(GenerationStatus.self, from: Data(last.dropFirst(5).utf8)),
            event.id == id, event.status == "completed" else {
            throw VoiceStudioError.invalidResponse(kind: .voicebox, detail: "Voicebox generation did not complete.")
        }

        let audio = makeRequest(
            url: context.endpoint.endpointURL(path: "audio/\(id)"), method: "GET", apiKey: context.apiKey, timeout: 60
        )
        let result = try await performValidated(
            audio, context: context,
            budget: .init(limit: maxAudioBytes, deadline: ContinuousClock.now.duration(to: deadline))
        )
        return try normalizeAudioBytes(result.body, kind: .voicebox)
    }
}

private struct GenerationStatus: Decodable {
    let id: String
    let status: String
}
