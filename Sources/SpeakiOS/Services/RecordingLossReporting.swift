#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// Nonfatal warning delivery shared by the four recording owners. The audio tap
/// only updates the run's counters; a cancellable main-actor task observes them.
@MainActor
final class RecordingLossReporting {
    var onWarning: ((String) -> Void)?
    private(set) var currentReport = RecordingLossReport()
    private(set) var finalSummary: String?
    private var monitoring: Task<Void, Never>?
    private var isActive = false
    private var didWarn = false
    private let isBatch: Bool

    init(isBatch: Bool = false) { self.isBatch = isBatch }

    private func contextualSummary(_ summary: String?) -> String? {
        summary.map { isBatch ? $0 + " Batch transcription may also be incomplete." : $0 }
    }

    func begin(recorder: AudioRecordingPersistence) {
        cancel()
        let report = RecordingLossReport()
        currentReport = report
        finalSummary = nil
        didWarn = false
        isActive = true
        recorder.onPersistenceIssue = { diagnostics in report.recordPersistence(diagnostics) }
        monitoring = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.currentReport === report, self.isActive else { return }
                self.deliverWarningIfNeeded()
            }
        }
    }

    /// Called before installing/starting the tap; writer failure never cancels a live provider.
    func startWriter(_ recorder: AudioRecordingPersistence, format: AVAudioFormat) {
        do { try recorder.startRecording(format: format) } catch { currentReport.writerCouldNotStart() }
    }

    func deliverWarningIfNeeded() {
        guard isActive, !didWarn, let summary = contextualSummary(currentReport.snapshot.summary) else { return }
        didWarn = true
        onWarning?(summary)
    }

    /// Caller has removed its tap and drained its existing processing queue.
    @discardableResult
    func finish(recorder: AudioRecordingPersistence, run: RecordingLossReport) -> RecordingInfo? {
        guard isActive, currentReport === run else { return nil }
        let recording = recorder.stopRecording()
        finalSummary = contextualSummary(run.finish(persistence: recording?.diagnostics).summary)
        isActive = false
        monitoring?.cancel()
        monitoring = nil
        recorder.onPersistenceIssue = nil
        return recording
    }

    func cancel() {
        isActive = false
        monitoring?.cancel()
        monitoring = nil
        currentReport.finish(persistence: nil)
        finalSummary = nil
    }
}

extension RecordingLossReport {
    /// The same admission path is used by every live tap, including both Apple paths.
    func copyCapture(_ buffer: AVAudioPCMBuffer, using pool: PCMBufferPool) -> AVAudioPCMBuffer? {
        guard let copy = pool.copy(buffer) else {
            rejectCapture(frameLength: buffer.frameLength, sampleRate: buffer.format.sampleRate)
            return nil
        }
        return copy
    }
}
#endif
