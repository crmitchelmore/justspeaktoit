#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// Finds audio that a crash, a jetsam kill or a battery cut left untranscribed,
/// and offers it back (issues #992, #1617).
///
/// Three rules govern everything here:
///
/// 1. **It never deletes a recording on its own.** Not an empty one, not one
///    it cannot read, not one the user put off. Audio is removed only when the
///    user picks Discard for that recording. "Keep" forgets the bookkeeping
///    record and leaves the audio in the saved-recording library.
/// 2. **It never touches a live capture.** ``CaptureRecoveryScanner`` decides
///    that from positive evidence of life, and this type feeds it the runs it
///    knows are recording right now on top of that.
/// 3. **An answer sticks.** "Not now" puts off every capture it covered until
///    a newer interruption happens (``CaptureRecoveryPromptPolicy``), and a
///    recovery that fails says why and offers Discard, rather than leaving the
///    user to find the same prompt on the next launch.
@MainActor
public final class CaptureRecoveryCoordinator: ObservableObject {
    public static let shared = CaptureRecoveryCoordinator()

    /// What the last Transcribe did, for the screen that asked.
    public enum Outcome: Equatable {
        /// The transcript is in History under this identifier.
        case recovered(historyID: UUID)
        /// Nothing was saved; the audio is still on the device.
        case failed(CaptureRecoveryFinding, message: String)
    }

    /// Everything the coordinator does outside its own state. Injectable so a
    /// test can drive recovery without a provider, History or the container.
    @MainActor
    struct Dependencies {
        var listFiles: @MainActor () -> [CaptureSafetyFile]
        var fileURL: @MainActor (String) -> URL
        var fileExists: @MainActor (URL) -> Bool
        /// Whether the file opens as audio with at least one frame. A capture
        /// killed mid-write can leave an AAC container with no index, which no
        /// provider can transcribe.
        var isTranscribableAudio: @MainActor (URL) -> Bool
        var deleteRecording: @MainActor (URL) -> Void
        var transcribe: @MainActor (URL) async throws -> String
        var recoveryModel: @MainActor () -> String
        var saveToHistory: @MainActor (iOSHistoryItem) async -> Bool
        var preferences: UserDefaults

        static func live(
            listFiles: @escaping @MainActor () -> [CaptureSafetyFile] = CaptureRecoveryCoordinator.listRecordingFiles
        ) -> Dependencies {
            Dependencies(
                listFiles: listFiles,
                fileURL: { AudioRecordingPersistence.recordingsDirectory.appendingPathComponent($0) },
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                isTranscribableAudio: CaptureRecoveryCoordinator.isTranscribableAudio(at:),
                deleteRecording: AudioRecordingPersistence.deleteRecording(at:),
                transcribe: { try await CaptureRecoveryCoordinator.transcribe(url: $0) },
                recoveryModel: CaptureRecoveryCoordinator.recoveryModel,
                saveToHistory: { await iOSHistoryManager.shared.upsertAndWait($0) },
                preferences: .standard
            )
        }
    }

    /// Interrupted captures whose audio was never transcribed and can be.
    @Published public private(set) var recoverable: [CaptureRecoveryFinding] = []
    /// Audio being kept because the pass could not establish what it was.
    @Published public private(set) var uncertain: [CaptureRecoveryFinding] = []
    /// Interrupted captures whose file is not readable audio, so there is
    /// nothing to transcribe. Never offered; listed so the user can discard.
    @Published public private(set) var unreadable: [CaptureRecoveryFinding] = []
    /// The recording currently being transcribed, if any.
    @Published public private(set) var recovering: UUID?
    /// The last failure, in words the user can act on.
    @Published public private(set) var errorMessage: String?
    /// The result of the last Transcribe, until the screen acknowledges it.
    @Published public private(set) var outcome: Outcome?
    /// Set once the launch prompt has been considered, so it is offered at
    /// most once per launch rather than every time the view reappears.
    @Published public var hasPromptedThisLaunch = false

    /// Where "Not now" is remembered. Per app, because only the app prompts.
    static let snoozedThroughKey = "captureRecoveryPromptSnoozedThrough.v1"

    private let claimStore: CaptureSafetyClaimStore
    private let dependencies: Dependencies
    private let logger = SpeakLogger.logger(category: "CaptureRecovery")

    public convenience init(
        claimStore: CaptureSafetyClaimStore = .shared,
        listFiles: @escaping () -> [CaptureSafetyFile] = CaptureRecoveryCoordinator.listRecordingFiles
    ) {
        self.init(claimStore: claimStore, dependencies: .live(listFiles: listFiles))
    }

    init(claimStore: CaptureSafetyClaimStore, dependencies: Dependencies) {
        self.claimStore = claimStore
        self.dependencies = dependencies
    }

    /// The files in the safety-recording directory, as names and sizes. The
    /// scan never opens one; only a capture whose owner is provably gone is
    /// opened, read-only, to check it holds audio.
    public static func listRecordingFiles() -> [CaptureSafetyFile] {
        AudioRecordingPersistence.listRecordings().map {
            CaptureSafetyFile(fileName: $0.url.lastPathComponent, byteSize: $0.fileSize)
        }
    }

    /// Whether a file opens as audio with at least one frame.
    nonisolated static func isTranscribableAudio(at url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0 && file.fileFormat.sampleRate > 0
    }

    /// Re-runs the pass. Safe to call at any time, including while a capture
    /// is running.
    @discardableResult
    public func refresh(now: Date = Date()) -> CaptureRecoveryPlan {
        let plan = CaptureRecoveryScanner.scan(CaptureRecoveryInput(
            claims: self.claimStore.claims(),
            files: self.dependencies.listFiles(),
            currentOwner: CaptureSafetyClaimStore.currentOwner,
            liveRuns: self.liveRuns(),
            now: now
        ))
        // Only captures whose owner is gone reach here, so opening one can
        // never race the process writing it.
        var readable: [CaptureRecoveryFinding] = []
        var unreadable: [CaptureRecoveryFinding] = []
        for finding in plan.recoverable {
            if self.dependencies.isTranscribableAudio(self.dependencies.fileURL(finding.fileName)) {
                readable.append(finding)
            } else {
                unreadable.append(finding)
            }
        }
        self.recoverable = readable
        self.unreadable = unreadable
        self.uncertain = plan.uncertain
        // The only records dropped automatically are those whose file has
        // already gone, so this frees bookkeeping and never audio.
        self.claimStore.forget(recordings: plan.claimsToForget)
        return plan
    }

    /// Captures writing right now in this process, so a claim for one is
    /// unreachable by every age-based rule in the scanner.
    private func liveRuns() -> Set<UUID> {
        AudioRecordingPersistence.activeClaims
    }

    // MARK: - Launch prompt

    /// The captures the launch prompt may offer: transcribable, and newer
    /// than everything the user already answered "Not now" to.
    public var promptable: [CaptureRecoveryFinding] {
        CaptureRecoveryPromptPolicy.promptable(self.recoverable, snoozedThrough: self.snoozedThrough)
    }

    private var snoozedThrough: Date? {
        self.dependencies.preferences.object(forKey: Self.snoozedThroughKey) as? Date
    }

    /// "Not now": stop asking about these captures until a newer one is
    /// interrupted. The audio and its Capture Health entry are untouched.
    public func snooze(_ findings: [CaptureRecoveryFinding]) {
        guard let watermark = CaptureRecoveryPromptPolicy.snoozedThrough(
            after: findings, current: self.snoozedThrough
        ) else { return }
        self.dependencies.preferences.set(watermark, forKey: Self.snoozedThroughKey)
    }

    /// The sentence the launch prompt shows. Content-free: a time and a count,
    /// never a transcript.
    public func promptMessage(for finding: CaptureRecoveryFinding) -> String {
        let time = finding.startedAt.formatted(date: .abbreviated, time: .shortened)
        var message = "A recording started \(time) was interrupted before its transcript was saved. "
            + "The audio is still here."
        let others = self.promptable.count - 1
        if others > 0 {
            message += " \(others) more \(others == 1 ? "is" : "are") listed in Settings › Capture Health."
        }
        return message
    }

    // MARK: - Actions

    /// Transcribes a recovered file and files the result in History.
    ///
    /// The audio file is left exactly where it is whether this succeeds or
    /// fails, so a failed recovery can be retried or discarded deliberately.
    /// The result is published as ``outcome`` for the screen that asked.
    @discardableResult
    public func recover(_ finding: CaptureRecoveryFinding) async -> Bool {
        guard self.recovering == nil else { return false }
        self.recovering = finding.run
        self.errorMessage = nil
        self.outcome = nil
        defer { self.recovering = nil }

        let url = self.dependencies.fileURL(finding.fileName)
        guard self.dependencies.fileExists(url) else {
            self.fail(finding, "That recording is no longer on this device.")
            self.refresh()
            return false
        }
        guard self.dependencies.isTranscribableAudio(url) else {
            self.fail(finding, "That recording holds no audio that can be transcribed.")
            self.refresh()
            return false
        }

        do {
            // A provider request that never returns would otherwise hold the
            // single recovering slot forever: this recording could not be
            // retried and no other recording could be recovered. The bound
            // restores a retryable state; the audio is untouched either way.
            let transcribe = self.dependencies.transcribe
            let text = try await CaptureDeadline.result(
                of: { try await transcribe(url) },
                orNilAfter: CaptureRecoveryPolicy.recoveryDeadlineSeconds
            )
            guard let text else {
                self.fail(finding, "That recording is taking too long to transcribe. The audio is still here.")
                return false
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // No words came back, and the audio is the only evidence of
                // what was said. Keep it and say so rather than closing it out.
                self.fail(finding, "That recording produced no text. The audio is still here.")
                return false
            }
            // The History write and the claim removal are two steps, and a kill
            // between them used to leave the claim recoverable and produce a
            // second History row for the same audio on the retry. The recovered
            // item's identity *is* the claim's run, so History already replaces
            // by id: retrying an interrupted recovery re-files the same row
            // rather than adding another.
            let durable = await self.saveRecovered(trimmed, for: finding)
            guard durable else {
                self.fail(finding, "History could not be saved. The audio is still here.")
                return false
            }
            // Bookkeeping only. The audio stays in Saved Recordings.
            self.claimStore.forget(recording: finding.run)
            self.refresh()
            self.outcome = .recovered(historyID: finding.run)
            return true
        } catch {
            // Never the error's message in the log: a batch transcription
            // failure is built from the provider's raw HTTP response body, and
            // this log is public. The status is the only remote-derived number.
            self.logger.error(
                """
                Recovery failed: \
                \(RemoteFailureLabel.label(for: error, status: Self.httpStatus(of: error)), privacy: .public)
                """
            )
            self.fail(finding, Self.failureMessage(for: error))
            return false
        }
    }

    /// Deletes a recovered capture's audio. Only ever called from a Discard the
    /// user chose for this recording.
    public func discard(_ finding: CaptureRecoveryFinding) {
        guard self.recovering != finding.run else { return }
        self.dependencies.deleteRecording(self.dependencies.fileURL(finding.fileName))
        self.claimStore.forget(recording: finding.run)
        if case .failed(let failed, _) = self.outcome, failed.run == finding.run { self.outcome = nil }
        self.errorMessage = nil
        self.refresh()
    }

    /// The screen has shown ``outcome``.
    public func acknowledgeOutcome() {
        self.outcome = nil
    }

    private func saveRecovered(_ text: String, for finding: CaptureRecoveryFinding) async -> Bool {
        await self.dependencies.saveToHistory(iOSHistoryItem(
            id: finding.run,
            createdAt: finding.startedAt,
            transcription: text,
            model: self.dependencies.recoveryModel(),
            duration: 0,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            originPlatform: Self.recoveredOrigin
        ))
    }

    private func fail(_ finding: CaptureRecoveryFinding, _ message: String) {
        self.errorMessage = message
        self.outcome = .failed(finding, message: message)
    }

    /// Stops offering a recovery without touching its audio.
    public func keepWithoutTranscribing(_ finding: CaptureRecoveryFinding) {
        self.claimStore.forget(recording: finding.run)
        self.refresh()
    }

    /// Marks a history item as one that came back from an interrupted capture.
    /// Local vocabulary on the existing `originPlatform` field rather than a
    /// new column.
    public static let recoveredOrigin = "ios-recovered"

    // MARK: - Transcription

    /// Re-transcribes a saved file with the configured batch model. Shared
    /// with the saved-recording library's re-transcribe action, so both routes
    /// resolve the model, key and language the same way.
    public static func transcribe(url: URL) async throws -> String {
        try await Self.transcribe(url: url, model: Self.recoveryModel())
    }

    /// Re-transcribes a saved file with a named batch model. Offline upgrades
    /// (issue #999) use the model the capture was meant to run with.
    /// `shouldProceed` is asked once credentials are ready, immediately before
    /// the upload; declining throws `CancellationError` and sends nothing.
    static func transcribe(
        url: URL, model: String, shouldProceed: @MainActor () -> Bool = { true }
    ) async throws -> String {
        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        guard shouldProceed() else { throw CancellationError() }
        // A failed Keychain load is not a missing key (issue #930): refuse
        // rather than submit the placeholder empty credential.
        try settings.requireAvailableCredentials(for: model, purpose: .batchTranscription)
        let key = settings.batchAPIKey(for: model)
        let language = TranscriptionLanguageCatalog.providerLanguage(
            for: settings.preferredLocaleIdentifier
        )
        let result = try await IOSBatchTranscriber.transcribeFile(
            at: url,
            model: model,
            apiKey: key,
            language: language,
            keywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords)
        )
        return result.text
    }

    /// The batch model a recovery runs through. Falls back to the first
    /// supported batch model when the selected one only works live, because a
    /// recovery has a file and no microphone.
    static func recoveryModel() -> String {
        let selected = AppSettings.shared.selectedModel
        if AppSettings.supportedBatchModels.contains(where: { $0.id == selected }) {
            return selected
        }
        return AppSettings.supportedBatchModels.first?.id ?? selected
    }
}

extension CaptureRecoveryCoordinator {
    /// What the user is told when the provider route failed. Never the raw
    /// provider body; the HTTP status alone is enough to act on.
    static func failureMessage(for error: Error) -> String {
        let kept = " The audio is still here."
        if error is AppSettings.CredentialLoadingError {
            return "API keys could not be loaded. Unlock \(DeviceCopy.yourDevice) and try again." + kept
        }
        if error is TranscriptionModelUnavailableError {
            return "The transcription model needs an API key. Add one in Settings, then try again." + kept
        }
        if let batch = error as? IOSBatchTranscriptionError {
            switch batch {
            case .apiKeyMissing:
                return "The transcription model needs an API key. Add one in Settings, then try again." + kept
            case .httpError(let service, let status, _):
                return "\(service) could not transcribe that recording (HTTP \(status))." + kept
            case .audioTooLarge:
                return "That recording is too large to upload." + kept
            default:
                break
            }
        }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "You are offline. Try again when you are connected." + kept
        }
        return "Could not transcribe that recording." + kept
    }

    /// The HTTP status of a provider rejection, when the error carries one.
    /// A number, never the response body that sits beside it.
    fileprivate static func httpStatus(of error: Error) -> Int? {
        guard let batch = error as? IOSBatchTranscriptionError,
              case .httpError(_, let status, _) = batch else { return nil }
        return status
    }
}

#endif
