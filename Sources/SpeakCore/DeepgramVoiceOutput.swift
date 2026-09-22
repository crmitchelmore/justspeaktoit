import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Speaks one Deepgram request at a time through a platform's native file
/// player.
///
/// Text that is empty after pronunciation returns `.nothingToSpeak` before the
/// credential closure, network, file or player is used. Otherwise the
/// credential is read once, Deepgram is asked once, and the validated audio is
/// stored in one platform-owned file and played. The file is discarded only
/// after the player has returned, whatever the outcome. Task cancellation
/// reaches the HTTP exchange and the player, and is checked between stages,
/// so a cancelled request never reports speech; the first failure stops the
/// request. A second request while one is active is refused, not queued, so
/// an instance holds at most one response and one file.
public final class DeepgramVoiceOutput: @unchecked Sendable {
    /// A platform's private file storage and native player for synthesized
    /// speech.
    public struct Playback: Sendable {
        let store: @Sendable (Data) throws -> URL
        let play: @Sendable (URL) async throws -> TimeInterval
        let discard: @Sendable (URL) -> Void

        /// - Parameters:
        ///   - store: Creates a new private file holding the WAV bytes. It must
        ///     never open, truncate or replace an existing file.
        ///   - play: Plays the file and returns the audio actually rendered, in
        ///     seconds, only after the native player has released the file.
        ///     Cancellation of the calling task must stop playback.
        ///   - discard: Removes a file `store` created. Called exactly once for
        ///     every stored file, after `play` returned or instead of it.
        public init(
            store: @escaping @Sendable (Data) throws -> URL,
            play: @escaping @Sendable (URL) async throws -> TimeInterval,
            discard: @escaping @Sendable (URL) -> Void
        ) {
            self.store = store
            self.play = play
            self.discard = discard
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The text was empty after pronunciation. No credential, request, file
        /// or playback was used.
        case nothingToSpeak
        case spoken(Receipt)
    }

    public struct Receipt: Equatable, Sendable {
        /// The canonical voice that spoke.
        public let voice: DeepgramSpeechCatalog.Voice
        /// Unicode scalars sent after pronunciation and trimming.
        public let characterCount: Int
        /// Duration of the synthesized audio.
        public let audioDuration: TimeInterval
        /// Audio the platform player reports it rendered.
        public let playedDuration: TimeInterval
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Another request on this instance is still active.
        case busy
        /// The player finished without rendering any audio.
        case noAudioPlayed
    }

    private let synthesizer: DeepgramSpeechSynthesizer
    private let playback: Playback
    private let lock = NSLock()
    private var active = false

    public convenience init(session: URLSession = .shared, playback: Playback) {
        self.init(synthesizer: DeepgramSpeechSynthesizer(session: session), playback: playback)
    }

    init(synthesizer: DeepgramSpeechSynthesizer, playback: Playback) {
        self.synthesizer = synthesizer
        self.playback = playback
    }

    /// - Parameter credential: Supplies the Deepgram API key. Called at most
    ///   once, and only when there is something to speak; the key is sent only
    ///   in the `Authorization` header.
    public func speak(
        _ request: DeepgramSpeechRequest,
        credential: @Sendable () async throws -> String
    ) async throws -> Outcome {
        try Task.checkCancellation()
        guard let utterance = try synthesizer.utterance(for: request) else { return .nothingToSpeak }
        guard admit() else { throw Failure.busy }
        defer { lock.withLock { active = false } }

        let (file, synthesized) = try await synthesizeAndStore(utterance, credential: credential)
        let played: TimeInterval
        do {
            try Task.checkCancellation()
            played = try await playback.play(file)
        } catch {
            playback.discard(file)
            throw error
        }
        playback.discard(file)
        guard played.isFinite, played > 0 else { throw Failure.noAudioPlayed }
        return .spoken(Receipt(
            voice: utterance.voice, characterCount: utterance.characterCount,
            audioDuration: synthesized, playedDuration: played
        ))
    }

    private func admit() -> Bool {
        lock.withLock {
            guard !active else { return false }
            active = true
            return true
        }
    }

    /// The response bytes stay local to this call, so they are released before
    /// playback starts.
    private func synthesizeAndStore(
        _ utterance: DeepgramSpeechSynthesizer.Utterance,
        credential: @Sendable () async throws -> String
    ) async throws -> (URL, TimeInterval) {
        let supplied = try await credential()
        let apiKey = try Self.validatedCredential(supplied)
        try Task.checkCancellation()
        let audio = try await synthesizer.synthesize(utterance, apiKey: apiKey)
        try Task.checkCancellation()
        return (try playback.store(audio.wav), audio.duration)
    }

    /// Surrounding whitespace is ignored. A key that could corrupt the header or
    /// is implausibly long is refused before any request.
    static func validatedCredential(_ credential: String) throws -> String {
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DeepgramSpeechError.missingCredential }
        guard key.utf8.count <= 4_096, key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw DeepgramSpeechError.invalidCredential
        }
        return key
    }
}

extension DeepgramVoiceOutput.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .busy: return "Voice output is already speaking."
        case .noAudioPlayed: return "Playback ended without rendering any audio."
        }
    }
}
