#if os(iOS)
import Foundation
import SpeakCore

/// Finds audio that a crash, a jetsam kill or a battery cut left untranscribed,
/// and offers it back (issue #992).
///
/// Two rules govern everything here:
///
/// 1. **It never deletes a recording.** Not an empty one, not one it cannot
///    identify, not one the user declined. "Keep" forgets the bookkeeping
///    record and leaves the audio in the saved-recording library, where it can
///    be played, re-transcribed or deleted deliberately. The only path that
///    removes audio in this feature is the one where the user cancelled the
///    capture themselves.
/// 2. **It never touches a live capture.** ``CaptureRecoveryScanner`` decides
///    that from positive evidence of life, and this type feeds it the runs it
///    knows are recording right now on top of that.
@MainActor
public final class CaptureRecoveryCoordinator: ObservableObject {
    public static let shared = CaptureRecoveryCoordinator()

    /// Interrupted captures whose audio was never transcribed.
    @Published public private(set) var recoverable: [CaptureRecoveryFinding] = []
    /// Audio being kept because the pass could not establish what it was.
    @Published public private(set) var uncertain: [CaptureRecoveryFinding] = []
    /// The recording currently being transcribed, if any.
    @Published public private(set) var recovering: UUID?
    /// The last failure, in words the user can act on.
    @Published public private(set) var errorMessage: String?
    /// Set once the launch prompt has been shown, so it is offered once per
    /// launch rather than every time the view reappears.
    @Published public var hasPromptedThisLaunch = false

    private let claimStore: CaptureSafetyClaimStore
    private let listFiles: () -> [CaptureSafetyFile]
    private let logger = SpeakLogger.logger(category: "CaptureRecovery")

    public init(
        claimStore: CaptureSafetyClaimStore = .shared,
        listFiles: @escaping () -> [CaptureSafetyFile] = CaptureRecoveryCoordinator.listRecordingFiles
    ) {
        self.claimStore = claimStore
        self.listFiles = listFiles
    }

    /// The files in the safety-recording directory, as names and sizes. The
    /// pass never opens one.
    public static func listRecordingFiles() -> [CaptureSafetyFile] {
        AudioRecordingPersistence.listRecordings().map {
            CaptureSafetyFile(fileName: $0.url.lastPathComponent, byteSize: $0.fileSize)
        }
    }

    /// Re-runs the pass. Safe to call at any time, including while a capture
    /// is running.
    @discardableResult
    public func refresh(now: Date = Date()) -> CaptureRecoveryPlan {
        let plan = CaptureRecoveryScanner.scan(CaptureRecoveryInput(
            claims: self.claimStore.claims(),
            files: self.listFiles(),
            currentOwner: CaptureSafetyClaimStore.currentOwner,
            liveRuns: self.liveRuns(),
            now: now
        ))
        self.recoverable = plan.recoverable
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

    /// The sentence the launch prompt shows. Content-free: a time and a size,
    /// never a transcript.
    public func promptMessage(for finding: CaptureRecoveryFinding) -> String {
        let time = finding.startedAt.formatted(date: .omitted, time: .shortened)
        return "A recording started at \(time) was interrupted before its transcript was saved. "
            + "The audio is still here."
    }

    // MARK: - Actions

    /// Transcribes a recovered file and files the result in History.
    ///
    /// The audio file is left exactly where it is whether this succeeds or
    /// fails, so a failed recovery can be retried from the saved-recording
    /// library rather than costing the user their audio.
    public func recover(_ finding: CaptureRecoveryFinding) async {
        guard self.recovering == nil else { return }
        self.recovering = finding.run
        self.errorMessage = nil
        defer { self.recovering = nil }

        let url = AudioRecordingPersistence.recordingsDirectory
            .appendingPathComponent(finding.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.errorMessage = "That recording is no longer on this device."
            self.refresh()
            return
        }

        do {
            // A provider request that never returns would otherwise hold the
            // single recovering slot forever: this recording could not be
            // retried and no other recording could be recovered. The bound
            // restores a retryable state; the audio is untouched either way.
            let text = try await CaptureDeadline.result(
                of: { try await Self.transcribe(url: url) },
                orNilAfter: CaptureRecoveryPolicy.recoveryDeadlineSeconds
            )
            guard let text else {
                self.errorMessage =
                    "That recording is taking too long to transcribe. The audio is kept in Saved Recordings."
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // No words came back, and the audio is the only evidence of
                // what was said. Keep it and say so rather than closing it out.
                self.errorMessage = "That recording produced no text. The audio is kept in Saved Recordings."
                return
            }
            // The History write and the claim removal are two steps, and a kill
            // between them used to leave the claim recoverable and produce a
            // second History row for the same audio on the retry. The recovered
            // item's identity *is* the claim's run, so History already replaces
            // by id: retrying an interrupted recovery re-files the same row
            // rather than adding another.
            iOSHistoryManager.shared.add(iOSHistoryItem(
                id: finding.run,
                createdAt: finding.startedAt,
                transcription: trimmed,
                model: Self.recoveryModel(),
                duration: 0,
                wordCount: trimmed.split(whereSeparator: \.isWhitespace).count,
                originPlatform: Self.recoveredOrigin
            ))
            // Bookkeeping only. The audio stays in Saved Recordings.
            self.claimStore.forget(recording: finding.run)
            self.refresh()
        } catch {
            // Never the error's message: a batch transcription failure is built
            // from the provider's raw HTTP response body, and this log is
            // public. The status is the only remote-derived number kept.
            self.logger.error(
                """
                Recovery failed: \
                \(RemoteFailureLabel.label(for: error, status: Self.httpStatus(of: error)), privacy: .public)
                """
            )
            self.errorMessage = "Could not transcribe that recording. The audio is kept in Saved Recordings."
        }
    }

    /// The HTTP status of a provider rejection, when the error carries one.
    /// A number, never the response body that sits beside it.
    private static func httpStatus(of error: Error) -> Int? {
        guard let batch = error as? IOSBatchTranscriptionError,
              case .httpError(_, let status, _) = batch else { return nil }
        return status
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
        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        let model = Self.recoveryModel()
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
#endif
