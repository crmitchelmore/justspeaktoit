import Foundation

/// Apple-only speech synthesis. The MP3 reply streams through `URLSession.bytes(for:)` into
/// a private 0600 temporary file (`OpenRouterAudioClient+Download.swift`). Native Windows
/// voice output is a separate adapter, so this file stays out of the portable graph rather
/// than offering an unsupported method there.
extension OpenRouterAudioClient {
    public func synthesize(
        text: String,
        model: String,
        voice: String?,
        speed: Double? = nil
    ) async throws -> OpenRouterSpeechResult {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 64 * 1024,
              voice.map(OpenRouterSpeechSelection.isValidVoice) ?? true,
              speed.map({ $0.isFinite && (0.25...4).contains($0) }) ?? true
        else { throw OpenRouterAudioError.invalidInput }
        var request = try await makeRequest(path: "speech", model: model)
        request.httpBody = try JSONEncoder().encode(
            OpenRouterSpeechRequest(model: model, input: text, voice: voice, speed: speed)
        )
        let file = try await downloadSpeech(request)
        do {
            try Task.checkCancellation()
            return OpenRouterSpeechResult(audioURL: file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private func downloadSpeech(_ request: URLRequest) async throws -> URL {
        let destination = temporaryDirectory.appendingPathComponent("openrouter-\(UUID().uuidString).mp3")
        do {
            return try await OpenRouterAudioDownload.perform(
                request: request, session: session, destination: destination, limit: maximumSpeechBytes, speech: true
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Self.audioError(from: error)
        }
    }
}
