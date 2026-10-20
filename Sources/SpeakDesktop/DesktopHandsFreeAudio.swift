import Foundation
import SpeakCore

/// In-process sound activation, not Apple's speech classifier. Quiet PCM never
/// reaches a file or provider; startup PCM is bounded and overflow disarms.
package final class DesktopHandsFreeAudio: @unchecked Sendable {
    private enum Phase: Equatable {
        case suspended, listening, starting, recording, closed
    }
    private let lock = NSLock()
    private var phase = Phase.suspended
    private var buffered = Data()
    private var seconds = 0.0
    private var tracker = HandsFreeVoiceActivityTracker()
    private var sink: (@Sendable (Data) -> Void)?
    private let sampleRate: Int
    private let threshold: Double
    private let hold: Double
    private let onEvent: @Sendable (HandsFreeDictationMachine.Event) -> Void
    private let onFailure: @Sendable (String) -> Void

    package init(
        sampleRate: Int, threshold: Double, hold: Double,
        onEvent: @escaping @Sendable (HandsFreeDictationMachine.Event) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.hold = hold
        self.onEvent = onEvent
        self.onFailure = onFailure
    }

    package var bufferedBytes: Int { lock.withLock { buffered.count } }

    package func resumeListening() {
        lock.withLock {
            guard phase != .closed else { return }
            phase = .listening
            buffered.removeAll(keepingCapacity: true)
            tracker.reset()
            sink = nil
        }
    }

    package func receive(_ samples: UnsafePointer<Int16>, count: Int) {
        let level = DictationSilencePolicy.normalizedLevel(UnsafeBufferPointer(start: samples, count: count))
        let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        var event: HandsFreeDictationMachine.Event?
        var overflow = false
        lock.withLock {
            seconds += Double(count) / Double(sampleRate)
            switch phase {
            case .closed, .suspended: return
            case .starting:
                // A slow file/credential operation must not truncate first words.
                guard buffered.count + data.count <= sampleRate * 2 * 3 else {
                    phase = .closed
                    buffered.removeAll()
                    overflow = true
                    return
                }
                buffered.append(data)
                return
            case .listening:
                buffered.append(data)
                let maximum = Int(Double(sampleRate * 2) * HandsFreeDictationPolicy.preRollSeconds)
                if buffered.count > maximum { buffered.removeFirst(buffered.count - maximum) }
            case .recording:
                sink?(data)
            }
            event = tracker.observe(speechDetected: level >= threshold, atSeconds: seconds, silenceHoldSeconds: hold)
            if event == .speechDetected, phase == .listening { phase = .starting }
        }
        if overflow { onFailure("Hands-free startup exceeded its bounded audio buffer. Audio capture stopped.") }
        if let event { onEvent(event) }
    }

    package func attach(_ sink: @escaping @Sendable (Data) -> Void) throws {
        try lock.withLock {
            guard phase == .starting else {
                throw DesktopHandsFreeAudioError.listeningEnded
            }
            sink(buffered)
            buffered.removeAll(keepingCapacity: true)
            self.sink = sink
            phase = .recording
        }
    }

    /// Joining the sink under the same lock precedes WAV finalization.
    package func suspend() {
        lock.withLock {
            guard phase != .closed else { return }
            phase = .suspended
            sink = nil
            buffered.removeAll(keepingCapacity: true)
            tracker.reset()
        }
    }

    package func close() {
        lock.withLock {
            phase = .closed
            sink = nil
            buffered.removeAll()
            tracker.reset()
        }
    }
}

package enum DesktopHandsFreeAudioError: LocalizedError {
    case listeningEnded
    package var errorDescription: String? { "Hands-free listening ended before recording could start." }
}
