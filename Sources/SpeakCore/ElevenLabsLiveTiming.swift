import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ElevenLabsLiveClient {
    /// The client's readiness, commit and finish bounds. Production uses the
    /// documented statics; tests shorten them to run in real time.
    struct Timing: Sendable {
        /// How long a finish that lands before `session_started` waits for it.
        let readiness: TimeInterval
        /// How long a sent manual commit waits for its `committed_transcript`.
        let postCommitDrain: TimeInterval
        /// The whole finish: readiness, queued sends and both commits.
        let overall: TimeInterval
        /// The handshake plus `session_started`, while recording.
        var startup: TimeInterval = ElevenLabsLiveClient.readyDeadline

        static let production = Timing(
            readiness: ElevenLabsLiveClient.finishReadyBudget,
            postCommitDrain: ElevenLabsLiveClient.finishBudget,
            overall: ElevenLabsLiveClient.finishDrainBudget
        )
    }

    /// Test seam: real-time scheduling with explicit, short bounds.
    convenience init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
        language: String? = nil,
        sampleRate: Int = LiveTranscriptionProviderID.elevenlabs.expectedSampleRate,
        timing: Timing,
        socketFactory: @escaping ConnectionFactory
    ) {
        self.init(
            apiKey: apiKey, modelID: modelID, language: language, sampleRate: sampleRate, timing: timing,
            makeConnection: socketFactory,
            schedule: { seconds, action in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
            }
        )
    }
}

/// Pairs a `committed_transcript` with its `committed_transcript_with_timestamps`
/// twin. With timestamps enabled ElevenLabs sends both forms for one segment;
/// either form may also arrive alone. A form that arrives while the other form
/// of a segment is outstanding is that segment again and must not count twice.
struct ElevenLabsFinalTwinTracker: Sendable {
    private var outstandingPlain = 0
    private var outstandingTimestamped = 0

    /// Records one final and reports whether it repeats a segment already counted.
    mutating func isTwin(timestamped: Bool) -> Bool {
        if timestamped {
            guard outstandingPlain == 0 else {
                outstandingPlain -= 1
                return true
            }
            outstandingTimestamped += 1
        } else {
            guard outstandingTimestamped == 0 else {
                outstandingTimestamped -= 1
                return true
            }
            outstandingPlain += 1
        }
        return false
    }
}
