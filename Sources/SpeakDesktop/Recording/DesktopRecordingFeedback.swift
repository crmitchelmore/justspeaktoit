import Foundation
import SpeakCore

public struct DesktopRecordingFeedbackPreferences: Equatable, Sendable {
    public let enabled: Bool
    public let profile: RecordingFeedbackProfile
    public let volume: Float

    public init(
        enabled: Bool = RecordingFeedbackDefaults.enabled,
        profile: RecordingFeedbackProfile = RecordingFeedbackDefaults.profile,
        volume: Float = Float(RecordingFeedbackDefaults.volume)
    ) throws {
        guard volume.isFinite, (0...1).contains(volume) else {
            throw DesktopRecordingFeedbackError.invalidVolume
        }
        self.enabled = enabled
        self.profile = profile
        self.volume = volume
    }
}

/// A dedicated predecoded feedback channel, never a History/Read aloud player.
public protocol DesktopRecordingFeedbackOutput: Sendable {
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void)
    func play(_ sound: RecordingFeedbackSound, gain: Float) throws
    /// Stops this channel's queued sound only; the prepared channel remains reusable.
    func stop()
    func close() async throws
}

public protocol DesktopRecordingFeedbackLoader: Sendable {
    /// Cancellation must abandon decoding and release any partially prepared output.
    func prepare(profile: RecordingFeedbackProfile) async throws -> any DesktopRecordingFeedbackOutput
}

/// No cue waits for decoding: a late preload must never beep into a newer recording.
public actor DesktopRecordingFeedback {
    private let loader: any DesktopRecordingFeedbackLoader
    private let report: @Sendable (String) -> Void
    private var preferences: DesktopRecordingFeedbackPreferences?
    private var output: (any DesktopRecordingFeedbackOutput)?
    private var preparation: Task<Void, Never>?
    private var retirements: [UUID: Task<Void, Never>] = [:]
    private var closing: Task<Void, Never>?
    private var generation = UUID()
    private var previewRevision = UUID()
    private var recordingID: UUID?
    private var started = false
    private var closed = false

    public init(loader: any DesktopRecordingFeedbackLoader, report: @escaping @Sendable (String) -> Void) {
        self.loader = loader
        self.report = report
    }

    public func configure(_ preferences: DesktopRecordingFeedbackPreferences) {
        guard !closed else { return }
        previewRevision = UUID()
        let replace = self.preferences?.profile != preferences.profile || !preferences.enabled
        self.preferences = preferences
        if replace { discardPreparationAndOutput() }
        if preferences.enabled { prepareIfNeeded() }
    }

    /// Reserves the identity before startup suspends; readiness alone cannot reserve it.
    public func recordingRequested(_ id: UUID) {
        guard !closed, recordingID != id else { return }
        previewRevision = UUID()
        output?.stop()
        recordingID = id
        started = false
    }

    /// Called only after native capture is ready, with the reserved recording identity.
    public func captureReady(_ id: UUID) {
        guard !closed, !started, recordingID == id else { return }
        started = true
        playIfReady(.start)
    }

    /// Called after the owned tail/capture stops normally, never on cancellation.
    public func recordingFinished(_ id: UUID) {
        guard !closed, started, recordingID == id else { return }
        recordingID = nil
        started = false
        playIfReady(.stop)
    }

    public func cancelRecording(_ id: UUID) {
        guard recordingID == id else { return }
        recordingID = nil
        started = false
        output?.stop()
    }

    /// Explicit preview may prepare a disabled profile but never overlaps a recording.
    public func preview(_ sound: RecordingFeedbackSound) async {
        guard !closed, !Task.isCancelled, recordingID == nil, preferences != nil else { return }
        prepareIfNeeded()
        let expected = generation
        previewRevision = UUID()
        let expectedPreview = previewRevision
        await preparation?.value
        guard !closed, !Task.isCancelled, recordingID == nil,
              generation == expected, previewRevision == expectedPreview else { return }
        guard let preferences else { return }
        play(sound, volume: preferences.volume)
    }

    public func close() async {
        if let closing { await closing.value; return }
        closed = true
        recordingID = nil
        started = false
        generation = UUID()
        let pending = preparation
        pending?.cancel()
        preparation = nil
        let output = self.output
        self.output = nil
        output?.stop()
        let retired = Array(retirements.values)
        let task = Task {
            if let output { await closeOutput(output) }
            await pending?.value
            for retirement in retired { await retirement.value }
        }
        closing = task
        await task.value
    }

    private func playIfReady(_ sound: RecordingFeedbackSound) {
        guard let preferences, preferences.enabled else { return }
        play(sound, volume: preferences.volume)
    }

    private func play(_ sound: RecordingFeedbackSound, volume: Float) {
        guard let output else {
            report("Recording sound is not ready; the cue was skipped rather than delayed.")
            return
        }
        do { try output.play(sound, gain: RecordingFeedbackDefaults.gain(for: volume)) } catch {
            report("Recording sound failed: \(error.localizedDescription)")
        }
    }

    private func prepareIfNeeded() {
        guard output == nil, preparation == nil, let preferences else { return }
        let profile = preferences.profile
        let loader = loader
        let expected = generation
        preparation = Task {
            do {
                let prepared = try await loader.prepare(profile: profile)
                if closed || generation != expected {
                    prepared.stop()
                    await closeOutput(prepared)
                } else {
                    prepared.setFailureHandler { [weak self] message in
                        Task { await self?.outputFailed(message, expected: expected) }
                    }
                    output = prepared
                    preparation = nil
                }
            } catch {
                guard !closed, generation == expected else { return }
                preparation = nil
                if !(error is CancellationError) {
                    report("Recording sound preparation failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func discardPreparationAndOutput() {
        generation = UUID()
        let pending = preparation
        pending?.cancel()
        preparation = nil
        let output = self.output
        self.output = nil
        output?.stop()
        guard pending != nil || output != nil else { return }
        let id = UUID()
        retirements[id] = Task {
            await pending?.value
            if let output { await closeOutput(output) }
            retirements.removeValue(forKey: id)
        }
    }

    private func closeOutput(_ output: any DesktopRecordingFeedbackOutput) async {
        do { try await output.close() } catch {
            report("Recording sound cleanup failed: \(error.localizedDescription)")
        }
    }

    private func outputFailed(_ message: String, expected: UUID) {
        guard !closed, generation == expected else { return }
        report("Recording sound output failed: \(message)")
        discardPreparationAndOutput()
    }
}

public enum DesktopRecordingFeedbackError: LocalizedError {
    case invalidVolume

    public var errorDescription: String? {
        "Recording sound volume must be a finite number between 0 and 1."
    }
}
