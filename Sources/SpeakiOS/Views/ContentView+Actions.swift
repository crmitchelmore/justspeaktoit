#if os(iOS)
import SpeakCore
import SwiftUI
import UIKit
import os.log

private let logger = SpeakLogger.logger(category: "ContentView")

/// Background-session surfacing, start/stop actions and failure recovery for
/// the transcription screen.
extension ContentView {
    // MARK: - Background session surfacing

    /// Starts recording on launch when the user asked for it. Considered once
    /// when onboarding was already complete and once more when the first-run
    /// sheet finishes, so enabling auto-start before onboarding is not silently
    /// dropped for the whole first launch.
    func autoStartIfEnabled() async {
        guard AppSettings.shared.autoStartRecording else { return }
        guard coordinator.state == .idle else { return }
        // A headless capture that is starting or finalising owns the
        // microphone as much as a running one; auto-start stands down rather
        // than alerting over a quick action the user just pressed.
        guard backgroundService.state == .idle else { return }
        let handle = ForegroundCaptureHandle()
        do {
            try await coordinator.start(handle: handle)
        } catch is CancellationError {
            // A manual tap or view cancellation retired this auto-start.
        } catch {
            self.presentStartFailure(error, snapshot: coordinator.issueSnapshot(failedStart: handle.runID))
        }
    }

    /// Presents a background session failure once.
    ///
    /// Called both when the published error changes and when this view
    /// appears — the second is what covers a cold launch, where a quick action
    /// can fail before any observer exists. `CaptureStartFailurePolicy` owns
    /// the "is this new?" rule so both routes agree, keyed on the publication
    /// rather than the message — two refusals can read identically, and the
    /// later one is still a new event that has to be shown.
    func presentSessionError(_ token: UUID?) {
        guard CaptureStartFailurePolicy.shouldPresent(
            token: token,
            lastPresented: presentedSessionError
        ) else {
            // A start clears the published failure; forget what was shown so
            // the next one is a new event whatever it says.
            if token == nil { presentedSessionError = nil }
            return
        }
        guard let error = backgroundService.lastSessionError else { return }
        let description = error.localizedDescription
        guard !description.isEmpty else { return }
        self.presentedSessionError = token
        self.issueErrorSnapshot = backgroundService.issueSnapshot(for: token)
        if let presentation = error as? CaptureStartFailurePresentation {
            self.errorMessage = presentation.message
            self.startFailureRecovery = presentation.recovery
        } else {
            self.errorMessage = description
            self.startFailureRecovery = nil
        }
        self.showingError = true
    }

    /// Surfaces the most recent background (Action Button / Siri / Shortcuts)
    /// transcript as the current view and updates the History badge. Called on
    /// appear and whenever the app returns to the foreground so a headless
    /// recording is never lost behind a stale in-app transcript.
    /// Offers the oldest interrupted capture back, once per launch, and only
    /// when nothing is recording — a question about yesterday's audio must not
    /// interrupt today's capture.
    func offerCaptureRecoveryIfNeeded() {
        guard !recovery.hasPromptedThisLaunch, !coordinator.isRunning else { return }
        let plan = recovery.refresh()
        guard !plan.hasLiveCapture, !plan.recoverable.isEmpty else { return }
        recovery.hasPromptedThisLaunch = true
        showingRecoveryPrompt = true
    }

    func refreshBackgroundState() {
        let shared = SharedTranscriptionState.shared
        showHistoryBadge = shared.hasUnseenBackgroundTranscript

        guard shared.hasUnseenBackgroundTranscript,
              !coordinator.isRunning,
              !backgroundService.isRunning,
              let text = shared.lastCompletedTranscript,
              !text.isEmpty else {
            return
        }

        // Surface a given background transcript only once. Comparing completion
        // timestamps stops repeated foreground cycles from overwriting the
        // user's in-app edits with the same background result.
        let completedAt = shared.lastCompletedAt
        if let surfaced = lastSurfacedAt, let completedAt, completedAt <= surfaced {
            return
        }
        displayText = text
        lastSurfacedAt = completedAt ?? Date()
    }

    /// Clears the History badge once the user opens History.
    func markHistorySeen() {
        SharedTranscriptionState.shared.markBackgroundTranscriptSeen()
        showHistoryBadge = false
    }

    // MARK: - Actions

    /// The manual button's starting state routes to cancellation (#943): the
    /// pending start is retired and awaited, never joined by a second one.
    func cancelStartingRecording() async {
        await coordinator.cancelStartup()
        if handsFree.isArmed { await handsFree.disarm() }
    }

    func toggleRecording() async {
        // Earliest app-code observation of this control's press; it survives
        // every await between here and the start path (issue #972).
        let pressedAt = Date()
        if coordinator.state == .starting {
            await cancelStartingRecording()
            return
        }
        // A finishing recording keeps ownership until its drain settles;
        // repeated taps neither cancel that finalisation nor start another.
        guard coordinator.state != .stopping else { return }
        if handsFree.state == .recording {
            await handsFree.finishCurrentUtterance()
        } else if handsFree.isArmed {
            await handsFree.disarm()
        } else if backgroundService.isRunning {
            // An in-app stop finishes a headless run where that run asked to
            // finish, not where the global setting points (issue #1013).
            let result = await backgroundService.stopRecording(
                selection: backgroundService.resolvedStopSelection()
            )
            displayText = result.text
        } else if coordinator.isRunning {
            let result = await coordinator.stop()
            logger.info("Final result: \(result.text.count) chars, duration: \(result.duration)s")

            // Auto post-process if enabled
            if settings.autoPostProcess && settings.hasOpenRouterKey && !result.text.isEmpty {
                showingPostProcessing = true
            }
        } else {
            await startInAppRecording(pressedAt: pressedAt)
        }
    }

    func startInAppRecording(pressedAt: Date) async {
        if settings.handsFreeDictationActive {
            await handsFree.toggle()
            return
        }
        // A background (Action Button) session owns the mic; don't start a
        // second, conflicting in-app recording. The user stops the background
        // one the same way they started it.
        guard !backgroundService.isRunning else {
            self.issueErrorSnapshot = IOSIssueReporter.failedRequest()
            self.startFailureRecovery = nil
            errorMessage = "A background recording is already in progress. "
                + "Use the Action Button to stop it."
            showingError = true
            return
        }

        // Clear previous text when starting new recording
        displayText = ""
        let handle = ForegroundCaptureHandle()
        do {
            try await coordinator.start(
                entry: StartupEntry(origin: .foreground, observedAt: pressedAt), handle: handle
            )
        } catch is CancellationError {
            // Intentional startup cancellation has no result or error alert.
        } catch {
            self.presentStartFailure(error, snapshot: coordinator.issueSnapshot(failedStart: handle.runID))
        }
    }

    func presentStartFailure(_ error: Error, snapshot: IOSIssueReportSnapshot? = nil) {
        self.issueErrorSnapshot = snapshot ?? IOSIssueReporter.failedRequest()
        let presentation = CaptureStartFailurePresentation.make(for: error)
        self.errorMessage = presentation.message
        self.startFailureRecovery = presentation.recovery
        self.showingError = true
    }

    func performStartFailureRecovery(_ recovery: CaptureStartFailureRecovery) {
        self.startFailureRecovery = nil
        switch recovery {
        case .appPermissions:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .credentials, .prepareAppleModel:
            self.recoveryDestination = recovery
        }
    }

    @ViewBuilder
    func startFailureRecoveryView(_ recovery: CaptureStartFailureRecovery) -> some View {
        switch recovery {
        case .credentials:
            APIKeysView(settings: self.settings)
        case .prepareAppleModel:
            Form {
                if #available(iOS 26.0, *) {
                    AppleSpeechPreparationView(
                        modelID: self.settings.selectedModel,
                        localeIdentifier: self.settings.preferredModelLanguage ?? Locale.current.identifier
                    )
                } else {
                    Text("Apple model preparation requires iOS 26 or later.")
                }
            }
            .navigationTitle("Prepare Apple Model")
            .navigationBarTitleDisplayMode(.inline)
        case .appPermissions:
            EmptyView()
        }
    }

    func copyToClipboard() {
        guard TranscriptClipboard.shared.copy(self.currentText) else { return }
        self.copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.copied = false
        }
    }
}
#endif
