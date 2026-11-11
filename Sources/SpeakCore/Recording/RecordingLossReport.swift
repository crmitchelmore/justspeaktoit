import Foundation

/// Session-only reporting; persistence admission remains owned by the writer.
/// Each capture run keeps its own instance, including in delayed callbacks.
public final class RecordingLossReport: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var rejectedBuffers = 0
        public var captureSeconds = 0.0
        public var persistence = RecordingPersistenceDiagnostics()
        public var couldNotStartWriter = false

        public var summary: String? {
            var messages: [String] = []
            if rejectedBuffers > 0 {
                messages.append(
                    "Some microphone audio was missed: \(rejectedBuffers) buffers (\(seconds(captureSeconds)) s)."
                )
            }
            if couldNotStartWriter {
                messages.append("The recording could not be saved.")
            } else if !persistence.isComplete {
                messages.append(
                    "The saved recording is incomplete: \(persistence.droppedFrames) writer drops "
                        + "(\(seconds(persistence.droppedSeconds)) s), \(persistence.writeFailures) write failures."
                )
            }
            return messages.isEmpty ? nil : messages.joined(separator: " ")
        }

        private func seconds(_ value: Double) -> String {
            String(format: "%.3f", locale: Locale(identifier: "en_GB"), value)
        }
    }

    private let lock = NSLock()
    private var stored = Snapshot()
    private var finished = false

    public init() {}

    public var snapshot: Snapshot { lock.withLock { stored } }

    /// Constant-time accounting only: no logging, notification or allocation per drop.
    public func rejectCapture(frameLength: UInt32, sampleRate: Double) {
        lock.withLock {
            guard !finished else { return }
            stored.rejectedBuffers += 1
            if sampleRate.isFinite && sampleRate > 0 {
                stored.captureSeconds += Double(frameLength) / sampleRate
            }
        }
    }

    public func recordPersistence(_ diagnostics: RecordingPersistenceDiagnostics) {
        lock.withLock {
            guard !finished else { return }
            stored.persistence = diagnostics
        }
    }

    public func writerCouldNotStart() {
        lock.withLock { stored.couldNotStartWriter = true }
    }

    /// The drained writer is authoritative even if its first notification is delayed.
    @discardableResult
    public func finish(persistence: RecordingPersistenceDiagnostics?) -> Snapshot {
        lock.withLock {
            if !finished, let persistence { stored.persistence = persistence }
            finished = true
            return stored
        }
    }
}
