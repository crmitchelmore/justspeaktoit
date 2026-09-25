import Foundation
import SpeakDesktop

/// Bounded waits for closing a desktop host.
package enum DesktopHostShutdown {
    /// How long closing waits in all for cancelled work to end: a provider,
    /// native recogniser, playback or output that ignores cancellation cannot
    /// keep the app from quitting.
    package static let grace: Duration = .seconds(5)

    /// Runs `work` in its own task and waits for it until `deadline`. Returns
    /// whether it ended; work still running then carries on unobserved.
    @discardableResult
    package static func wait(
        until deadline: ContinuousClock.Instant, for work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let outcome = DesktopHostShutdownOutcome()
        Task { await work(); outcome.settle(true) }
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            outcome.settle(false)
        }
        let ended = await outcome.value()
        timer.cancel()
        return ended
    }

    /// `wait(until:for:)` with a deadline `grace` from now.
    @discardableResult
    package static func wait(within grace: Duration, for work: @escaping @Sendable () async -> Void) async -> Bool {
        await wait(until: ContinuousClock.now.advanced(by: grace), for: work)
    }
}

/// What `close()` stopped waiting for when its grace period ended.
package struct DesktopHostShutdownReport: Equatable, Sendable {
    /// Whether the recording open at close was stopped and saved in time. Its
    /// record was saved when it began, so one still stopping is recovered with
    /// its audio at the next launch.
    package var recordingSaved = true
    /// Recordings, imports, retries and other operations still running. Each
    /// saved its record before any request or recognition, so History keeps
    /// the audio and marks the record interrupted at the next launch.
    package var unfinishedOperations = 0
    package var playbackClosed = true
    package var discoveryEnded = true

    package var isComplete: Bool {
        recordingSaved && unfinishedOperations == 0 && playbackClosed && discoveryEnded
    }

    package init() {}

    var summary: String {
        var parts: [String] = []
        if !recordingSaved { parts.append("the open recording still stopping") }
        if unfinishedOperations > 0 { parts.append("\(unfinishedOperations) background operation(s) still running") }
        if !playbackClosed { parts.append("audio playback still stopping") }
        if !discoveryEnded { parts.append("model discovery still running") }
        return "Closed after the shutdown grace period with " + parts.joined(separator: ", ")
            + ". Saved recordings are kept; an interrupted one is recovered at the next launch.\n"
    }
}

/// Decides a shutdown wait: the first of the work and the deadline to settle.
private final class DesktopHostShutdownOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func settle(_ ended: Bool) {
        let resume = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard result == nil else { return nil }
            result = ended
            defer { waiter = nil }
            return waiter
        }
        resume?.resume(returning: ended)
    }

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let settled = lock.withLock { () -> Bool? in
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let settled { continuation.resume(returning: settled) }
        }
    }
}

extension DesktopHostController {
    /// Stops recording, output, playback and every request, then gives the
    /// open recording and the cancelled work `shutdownGrace` in all to finish
    /// and completes whether or not they have. Work that ends later cannot
    /// reach the window or start anything, since each path checks `closed`
    /// after it suspends. What it already saved stays: a recording is saved
    /// when it begins and again before any request, and one left without an
    /// outcome is recovered, audio retained, at next launch.
    @discardableResult
    package func close() async -> DesktopHostShutdownReport {
        if closed {
            if shutdownReport == nil { await withCheckedContinuation { shutdownWaiters.append($0) } }
            return shutdownReport ?? DesktopHostShutdownReport()
        }
        closed = true
        let deadline = ContinuousClock.now.advanced(by: shutdownGrace)
        modelDiscoveryTask?.cancel()
        cancelOutput()
        cancellationRequested = true
        transcriptionTask?.cancel()
        postProcessingTask?.cancel()
        liveFinalisation?.cancel()
        var report = DesktopHostShutdownReport()
        // Stopping capture and writing the WAV and record run off this actor,
        // so a stalled device or file system cannot hold closing past its deadline.
        if let open = takeRecordingOnClose() {
            let store = store
            report.recordingSaved = await DesktopHostShutdown.wait(until: deadline) { await open.save(in: store) }
        }
        // Includes admitted opens and every background release attempt.
        let playback = playback
        report.playbackClosed = await DesktopHostShutdown.wait(until: deadline) {
            do { try await playback.close() } catch {
                FileHandle.standardError.write(Data("Playback cleanup failed: \(error.localizedDescription)\n".utf8))
            }
        }
        // The network task alone is insufficient: its owner must also finish
        // success/failure persistence and release native/file resources.
        if activeOperations > 0 {
            let ended = await DesktopHostShutdown.wait(until: deadline) { await self.operationsEnded() }
            if !ended { report.unfinishedOperations = activeOperations }
        }
        if let discovery = modelDiscoveryTask {
            report.discoveryEnded = await DesktopHostShutdown.wait(until: deadline) { await discovery.value }
        }
        modelDiscoveryTask = nil
        finishShutdown(report)
        return report
    }

    /// Hands the open recording over for closing to stop and save; the
    /// controller keeps no reference to its capture.
    private func takeRecordingOnClose() -> DesktopHostClosingRecording? {
        guard let active = recording else { return nil }
        recording = nil
        liveUpdates?.cancel()
        liveUpdates = nil
        return DesktopHostClosingRecording(
            capture: active.capture, file: active.context.file, live: active.live, record: active.record
        )
    }

    /// Returns once no operation runs, or once closing has stopped waiting.
    private func operationsEnded() async {
        guard activeOperations > 0, shutdownReport == nil else { return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    /// Releases every waiter, including a wait that ran out of time; an
    /// operation finishing later finds nobody waiting.
    private func finishShutdown(_ report: DesktopHostShutdownReport) {
        shutdownReport = report
        let operations = operationWaiters
        operationWaiters.removeAll()
        operations.forEach { $0.resume() }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !report.isComplete { FileHandle.standardError.write(Data(report.summary.utf8)) }
    }
}

/// The recording open when the controller closed. The controller hands over
/// its only reference to the capture, and nothing else touches it afterwards,
/// so stopping it on another thread keeps the serial start, stop and destroy
/// order `DesktopRecordingCapture` requires.
struct DesktopHostClosingRecording: @unchecked Sendable {
    let capture: any DesktopRecordingCapture
    let file: PCMRecordingFile
    let live: DesktopLiveSession?
    let record: DesktopRecordingStore.Record

    /// Stops capture, finalises the WAV and saves the record with its audio
    /// and any live text. If this outlives closing, the record saved when the
    /// recording began is recovered with its audio at the next launch.
    func save(in store: DesktopRecordingStore) async {
        var record = record
        record.failure = "Recording stopped when the app closed. Audio retained."
        var duration: TimeInterval = 0
        do { duration = try DesktopHostRecordingStop.stop(capture, file: file) } catch {
            record.failure = "\(record.failure ?? "Recording stopped.") \(error.localizedDescription)"
        }
        if let live {
            record.result = DesktopHostRecordingStop.liveResult(
                live.cancel().text, model: record.modelIdentifier, duration: duration
            )
        }
        do { try await store.save(record) } catch {
            FileHandle.standardError.write(Data("Could not persist recording on close.\n".utf8))
        }
    }
}
