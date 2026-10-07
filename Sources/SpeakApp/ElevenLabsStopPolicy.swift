import Foundation
import SpeakCore

/// The outer watchdog must outlive the same grace and drain used by this run.
/// The extra second allows terminal callbacks to return through the main actor;
/// it is a maximum, never an additional sleep on the successful path.
enum ElevenLabsStopPolicy {
    static func boundedGrace(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(max(value, 0), 2) : 0
    }

    static func completionTimeout(grace: TimeInterval) -> TimeInterval {
        ElevenLabsLiveClient.finishDrainBudget + boundedGrace(grace) + 1
    }
}
