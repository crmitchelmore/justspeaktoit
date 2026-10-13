import Foundation
import SpeakCore

/// One-shot fan-out. A common capture starts only after every usable lane's handshake.
/// Capture frames are delivered synchronously, with no unbounded host audio queue.
public final class DesktopComparisonLive: @unchecked Sendable {
    public struct Lane {
        public let candidate: DesktopComparisonCandidate
        public let client: any FinalizingStreamingTranscriptionClient
        public let sampleRate: Int

        public init(
            candidate: DesktopComparisonCandidate, client: any FinalizingStreamingTranscriptionClient, sampleRate: Int
        ) {
            self.candidate = candidate
            self.client = client
            self.sampleRate = sampleRate
        }
    }

    private final class State: @unchecked Sendable {
        let lane: Lane
        let session: DesktopLiveSession
        var entry: ModelComparisonEntry
        let lock = NSLock()
        init(_ lane: Lane) {
            self.lane = lane
            session = DesktopLiveSession(client: lane.client)
            entry = lane.candidate.entry()
        }
    }

    public let captureSampleRate = 24_000
    private let lanes: [State]
    private let calls = NSLock()
    private var capturing = false
    private var preparing = false
    private var terminal = false
    private var finishing: Task<[ModelComparisonEntry], Never>?
    private var startedAt: ContinuousClock.Instant?
    private var previousSample: Int16?
    private var sampleIndex = 0
    private var nextOutputNumerator = 0

    public init(lanes: [Lane]) throws {
        try DesktopComparisonRunner.validate(lanes.map(\.candidate))
        guard lanes.allSatisfy({ [16_000, 24_000].contains($0.sampleRate)
            && $0.client is any StreamingAudioReadyProviding }) else {
            throw DesktopComparisonError.message("A selected live route cannot provide comparison audio readiness.")
        }
        self.lanes = lanes.map(State.init)
    }

    public func prepare(timeout: Duration = .seconds(12)) async throws {
        let admitted = calls.withLock {
            guard !terminal, !preparing else { return false }
            preparing = true
            return true
        }
        guard admitted else { throw DesktopComparisonError.message("This comparison cannot prepare another capture.") }
        lanes.forEach { $0.session.start() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            guard !calls.withLock({ terminal }) else { throw CancellationError() }
            let pending = lanes.filter {
                $0.session.snapshot().phase == .recording
                    && ($0.lane.client as? any StreamingAudioReadyProviding)?.isReadyForAudio != true
            }
            if pending.isEmpty { break }
            if ContinuousClock.now >= deadline {
                for lane in pending {
                    lane.lock.withLock { lane.entry.errorDescription = "The model did not become ready in time." }
                    lane.session.cancel()
                }
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard lanes.contains(where: { $0.session.snapshot().phase == .recording }) else {
            throw DesktopComparisonError.message("No comparison model became ready. Check provider credentials.")
        }
        let ready = calls.withLock {
            guard !terminal else { return false }
            capturing = true
            return true
        }
        guard ready else { throw CancellationError() }
    }

    public func beginCapture() throws {
        let started = calls.withLock {
            guard capturing, !terminal, startedAt == nil else { return false }
            startedAt = .now
            return true
        }
        guard started else {
            throw DesktopComparisonError.message("The comparison capture is not ready or has already started.")
        }
    }

    public func sendAudio(_ data: Data) {
        calls.withLock {
            guard capturing, !terminal, data.count % 2 == 0 else { return }
            if startedAt == nil { startedAt = .now }
            // One common rate projection, so every 16 kHz lane gets identical bytes.
            let at16k = resample(data)
            for lane in lanes {
                lane.session.sendAudio(lane.lane.sampleRate == 24_000 ? data : at16k)
                let snapshot = lane.session.snapshot()
                if !snapshot.text.isEmpty, let startedAt {
                    lane.lock.withLock {
                        if lane.entry.timeToFirstPartialMs == nil {
                            lane.entry.timeToFirstPartialMs = DesktopComparisonRunner.milliseconds(
                                startedAt.duration(to: .now)
                            )
                        }
                    }
                }
            }
        }
    }

    public func finish(timeout: Duration = .seconds(30)) async -> [ModelComparisonEntry] {
        let task = calls.withLock { () -> Task<[ModelComparisonEntry], Never> in
            if let finishing { return finishing }
            let task = Task { await self.finishLanes(timeout: timeout) }
            finishing = task
            return task
        }
        return await task.value
    }

    private func finishLanes(timeout: Duration) async -> [ModelComparisonEntry] {
        let origin = calls.withLock { capturing = false; return startedAt }
        return await withTaskGroup(of: (Int, ModelComparisonEntry).self) { group in
            for (index, lane) in lanes.enumerated() {
                group.addTask {
                    let stoppedAt = ContinuousClock.now
                    var entry = lane.lock.withLock { lane.entry }
                    do {
                        let snapshot = try await DesktopComparisonDeadline.run(timeout: timeout) {
                            await lane.session.finish()
                        }
                        entry.transcript = snapshot.text
                        entry.errorDescription = entry.errorDescription ?? snapshot.error
                        if snapshot.phase == .cancelled, entry.errorDescription == nil {
                            entry.errorDescription = "Comparison cancelled."
                        }
                        if entry.errorDescription == nil, entry.transcript.isEmpty {
                            entry.errorDescription = "The model returned no transcript."
                        }
                    } catch {
                        let snapshot = lane.session.cancel()
                        entry.transcript = snapshot.text
                        entry.errorDescription = error is CancellationError
                            ? "Comparison cancelled." : error.localizedDescription
                    }
                    if let origin, let first = lane.session.firstTranscriptAt, first >= origin {
                        entry.timeToFirstPartialMs = DesktopComparisonRunner.milliseconds(origin.duration(to: first))
                    }
                    entry.timeToFinalMs = DesktopComparisonRunner.milliseconds(stoppedAt.duration(to: .now))
                    return (index, entry)
                }
            }
            var entries: [(Int, ModelComparisonEntry)] = []
            for await entry in group { entries.append(entry) }
            calls.withLock { terminal = true }
            return entries.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func cancel() {
        let task = calls.withLock { terminal = true; capturing = false; return finishing }
        lanes.forEach { $0.session.cancel() }
        task?.cancel()
    }

    public func snapshot() -> [ModelComparisonEntry] {
        lanes.map { lane in
            var entry = lane.lock.withLock { lane.entry }
            let snapshot = lane.session.snapshot()
            entry.transcript = snapshot.text
            entry.errorDescription = entry.errorDescription ?? snapshot.error
            return entry
        }
    }

    // Streaming linear interpolation, anchored to the common capture's sample index.
    // Fractional positions survive frame boundaries; no per-lane converter drift.
    private func resample(_ data: Data) -> Data {
        var output = Data()
        for offset in stride(from: 0, to: data.count, by: 2) {
            let sample = Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
            if let previousSample {
                while nextOutputNumerator <= sampleIndex * 2 {
                    let fraction = Double(nextOutputNumerator - (sampleIndex - 1) * 2) / 2
                    let value = Double(previousSample) + (Double(sample) - Double(previousSample)) * fraction
                    var pcm = Int16(clamping: Int(value.rounded())).littleEndian
                    withUnsafeBytes(of: &pcm) { output.append(contentsOf: $0) }
                    nextOutputNumerator += 3
                }
            } else {
                var pcm = sample.littleEndian
                withUnsafeBytes(of: &pcm) { output.append(contentsOf: $0) }
                nextOutputNumerator = 3
            }
            previousSample = sample
            sampleIndex += 1
        }
        return output
    }
}
