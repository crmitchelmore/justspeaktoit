import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The HTTP flow shared by desktop voices that return one complete WAV per
/// text segment (Groq Orpheus, Speechmatics). Each segment is one bounded
/// request with its own usage record; the PCM payloads are joined into one
/// WAV, and nothing is published unless every segment succeeds. How text is
/// segmented, what each request carries and what a rejected response means
/// stay with the provider.
struct DesktopSegmentedWAVSynthesis: Sendable {
    let session: URLSession
    let sampleRate: Int
    /// Builds the request for one segment with the resolved key.
    let request: @Sendable (_ text: String, _ key: String) throws -> URLRequest
    /// The provider's error for a non-2xx response.
    let serviceError: @Sendable (_ body: Data, _ statusCode: Int) -> Error

    func synthesize(
        _ segments: [String], voice: DesktopSpeechVoice, missingCredential: Error,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw missingCredential }
        return try await DesktopSpeechHTTP.joinedWAV(segments, sampleRate: sampleRate) { segment in
            try await synthesizeSegment(segment, key: key, voice: voice)
        }
    }

    private func synthesizeSegment(
        _ text: String, key: String, voice: DesktopSpeechVoice
    ) async throws -> DeepgramSpeechAudio {
        let request = try request(text, key)
        return try await DesktopSpeechHTTP.measuredSegment(
            sampleRate: sampleRate, requireComplete: true,
            begin: {
                $0.begin(voice: voice, inputCharacters: text.unicodeScalars.count,
                         usesSSML: false, pricingCharacters: text.count)
            },
            receive: { try await DesktopSpeechHTTP.receive(request, session: session, serviceError: serviceError) }
        )
    }
}
