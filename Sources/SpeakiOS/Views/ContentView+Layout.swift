#if os(iOS)
import SpeakCore
import SwiftUI
import UIKit

/// Layers, toolbar and presentation modifiers of the transcription screen,
/// split out so each group reads on its own; `body` composes them in the
/// original modifier order.
extension ContentView {
    var transcriptLayer: some View {
        VStack {
            captureNotices
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: density.isCompact ? density.cardContentSpacing : 12
                    ) {
                        if self.settings.isTranscriptClipboardNoticePending {
                            ClipboardPrivacyNotice(settings: self.settings)
                        }
                        if let card = onboarding.offeredCard(hardware: captureHardware) {
                            CaptureOnboardingCard(
                                trigger: card,
                                hasActionButton: captureHardware.hasActionButton
                            ) {
                                onboarding.dismissCard(card)
                            }
                        }
                        if backgroundService.isActive,
                           let destination = backgroundService.captureDestinationStatus {
                            Label(destination, systemImage: "arrow.turn.down.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("effectiveCaptureDestination")
                        }
                        if let warning = backgroundService.isRunning
                            ? backgroundService.recordingWarning : coordinator.recordingWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("recordingLossWarning")
                        }
                        if currentText.isEmpty {
                            Text(backgroundService.isRunning
                                 ? "Recording via Action Button…"
                                 : "Tap Transcribe to start")
                                .font(density.isCompact ? .subheadline : .title3)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, density.isCompact ? 24 : 100)
                        } else {
                            Text(currentText)
                                .font(density.isCompact ? .body : .title3)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(density.isCompact ? density.pagePadding : 16)
                    .id("transcript")
                }
                .onChange(of: coordinator.partialText) { _, _ in
                    // Update display text when recording (unless we have post-processed text)
                    if coordinator.isRunning {
                        displayText = ""  // Clear post-processed text during new recording
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("transcript", anchor: .bottom)
                    }
                }
                .onChange(of: backgroundService.partialText) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("transcript", anchor: .bottom)
                    }
                }
            }

            Spacer(minLength: density.isCompact ? 72 : 120)
        }
    }

    var controlsLayer: some View {
        VStack {
            Spacer()

            // Floating control cluster with Liquid Glass
            floatingControls
                .padding(.horizontal, density.isCompact ? 8 : 20)
                .padding(.bottom, density.isCompact ? 8 : 30)
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // Status indicator in toolbar (system handles glass)
        if coordinator.isRunning || backgroundService.isRunning {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    if coordinator.isRunning, let confidence = coordinator.confidence {
                        Text("\(Int(confidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    backgroundService.isRunning ? "Recording via Action Button" : "Recording"
                )
            }
        } else if handsFree.isArmed {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.caption)
                    Text(handsFreeStatusLabel)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hands-free dictation \(handsFreeStatusLabel.lowercased())")
                .accessibilityIdentifier("handsFreeArmedIndicator")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: density.isCompact ? 8 : 16) {
                NavigationLink {
                    HistoryView()
                        .onAppear { markHistorySeen() }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .overlay(alignment: .topTrailing) {
                            if showHistoryBadge {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 5, y: -4)
                            }
                        }
                }
                // A label that changes with the badge is dropped from the toolbar
                // button, leaving it unnamed; keep the name fixed and expose the
                // badge as the value (#1399).
                .accessibilityLabel("History")
                .accessibilityValue(showHistoryBadge ? "New background recording" : "")
                .accessibilityIdentifier("historyNavLink")

                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gear")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsNavLink")
            }
        }
    }

    /// Shown while a Transcribe started from the launch prompt runs, so the
    /// tap visibly does something (issue #1617).
    @ViewBuilder var recoveryProgressBanner: some View {
        if let inFlight = recoveryInFlight, recovery.recovering == inFlight {
            HStack(spacing: 8) {
                ProgressView()
                Text("Transcribing interrupted recording…")
                    .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("captureRecoveryProgress")
            .onAppear {
                AccessibilityNotification.Announcement("Transcribing interrupted recording").post()
            }
        }
    }

    func chrome(_ content: some View) -> some View {
        content
            .overlay(alignment: .top) { recoveryProgressBanner }
            .navigationTitle("Just Speak to It")
            .navigationBarTitleDisplayMode(usesInlineDensityLayout ? .inline : .automatic)
            .navigationDestination(item: $recoveryDestination) { destination in
                self.startFailureRecoveryView(destination)
            }
            .toolbar { toolbarContent }
    }

    func presentations(_ content: some View) -> some View {
        recoveryPresentations(content)
            .alert(errorAlertTitle, isPresented: $showingError) {
                if let recovery = self.startFailureRecovery {
                    Button(recovery.buttonTitle) { self.performStartFailureRecovery(recovery) }
                        .accessibilityIdentifier("captureStartRecoveryButton")
                }
                Button("Create Issue with Details…") {
                    self.issueReport = IOSIssueReportController(snapshot: self.issueErrorSnapshot)
                    self.startFailureRecovery = nil
                }
                Button("OK", role: .cancel) { self.startFailureRecovery = nil }
            } message: {
                Text(errorMessage)
            }
            // Asked once before any crash report is collected; "Don't send"
            // is a decision too, so the prompt never returns.
            .alert(DiagnosticsConsent.title + "?", isPresented: $showingDiagnosticsConsent) {
                Button("Send") { DiagnosticsConsent.shared.record(granted: true) }
                    .accessibilityIdentifier("diagnosticsConsentAllowButton")
                Button("Don't Send", role: .cancel) { DiagnosticsConsent.shared.record(granted: false) }
                    .accessibilityIdentifier("diagnosticsConsentDeclineButton")
            } message: {
                Text(DiagnosticsConsent.explanation + " You can change this in Settings > Privacy & Diagnostics.")
            }
            .navigationDestination(isPresented: Binding(
                get: { self.historyRouter.pendingHistoryID != nil },
                set: { if !$0 { self.historyRouter.pendingHistoryID = nil } }
            )) {
                if let identifier = self.historyRouter.pendingHistoryID {
                    IdentifiedHistoryView(identifier: identifier)
                }
            }
    }

    func recoveryPresentations(_ content: some View) -> some View {
        content
            // Audio that survived a crash, offered back at most once per launch
            // (issues #992, #1617). "Not now" puts it off until a newer
            // capture is interrupted; only Discard deletes audio.
            .alert(
                "Recording interrupted", isPresented: $showingRecoveryPrompt, presenting: recoveryPromptFinding
            ) { finding in
                Button("Transcribe it") { self.transcribeRecoveredCapture(finding) }
                    .accessibilityIdentifier("captureRecoveryTranscribeButton")
                Button("Discard recording", role: .destructive) { self.recovery.discard(finding) }
                    .accessibilityIdentifier("captureRecoveryDiscardButton")
                Button("Not now", role: .cancel) { self.snoozeCaptureRecovery() }
                    .accessibilityIdentifier("captureRecoveryNotNowButton")
            } message: { finding in
                Text(recovery.promptMessage(for: finding))
            }
            .alert(
                "Couldn't transcribe recording",
                isPresented: Binding(
                    get: { self.recoveryFailure != nil },
                    set: { if !$0 { self.recoveryFailure = nil } }
                ),
                presenting: recoveryFailure
            ) { finding in
                Button("Try again") { self.transcribeRecoveredCapture(finding) }
                    .accessibilityIdentifier("captureRecoveryRetryButton")
                Button("Discard recording", role: .destructive) { self.recovery.discard(finding) }
                    .accessibilityIdentifier("captureRecoveryFailureDiscardButton")
                Button("Keep for later", role: .cancel) { self.recovery.snooze([finding]) }
                    .accessibilityIdentifier("captureRecoveryKeepButton")
            } message: { _ in
                Text(recoveryFailureMessage)
            }
    }

    func observers(_ content: some View) -> some View {
        lifecycleObservers(failureObservers(content))
    }

    func failureObservers(_ content: some View) -> some View {
        content
            .onChange(of: coordinator.error?.localizedDescription) { _, newError in
                if let error = newError {
                    self.issueErrorSnapshot = coordinator.issueFailureSnapshot
                    self.startFailureRecovery = nil
                    self.errorIsStartFailure = false
                    errorMessage = error
                    showingError = true
                }
            }
            .onChange(of: backgroundService.sessionErrorToken) { _, token in
                // A background session (Action Button, Home Screen quick
                // action, capture link) failed; surface it instead of silently
                // losing the user's dictation. Observed on the publication
                // token, so a refusal that repeats word for word still arrives
                // as a new event.
                presentSessionError(token)
            }
            .onChange(of: handsFree.failureMessage) { _, newError in
                if let newError {
                    self.issueErrorSnapshot = IOSIssueReporter.failedRequest()
                    self.startFailureRecovery = nil
                    self.errorIsStartFailure = false
                    errorMessage = newError
                    showingError = true
                }
            }
            // A shared recording that could not be transcribed is reported,
            // never swallowed. Successes need no alert: they are in History.
            .onChange(of: sharedImporter.lastOutcome) { _, outcome in
                guard case .failed = outcome, let outcome else { return }
                self.issueErrorSnapshot = IOSIssueReporter.failedRequest()
                self.startFailureRecovery = nil
                self.errorIsStartFailure = false
                errorMessage = outcome.message
                showingError = true
                sharedImporter.acknowledgeOutcome()
            }
            .onChange(of: settings.handsFreeDictationEnabled) { _, enabled in
                if !enabled { Task { await handsFree.disarm() } }
            }
    }

    func lifecycleObservers(_ content: some View) -> some View {
        content
            .task {
                // The guided first run owns the microphone until it is done,
                // so never auto-start behind it. Auto-start is reconsidered
                // when onboarding finishes (see the sheet's onDismiss).
                if onboarding.shouldPresentFirstRun {
                    showingFirstRun = true
                } else {
                    showingDiagnosticsConsent = DiagnosticsConsent.shared.needsDecision
                    await autoStartIfEnabled()
                }
            }
            .onAppear {
                handsFree.sceneActivityChanged(isActive: scenePhase == .active)
                refreshBackgroundState()
                // A Home Screen quick action can cold-launch the app and fail
                // to start before this view — and therefore the observer above
                // — exists, so the failure has to be read as well as watched
                // (issue #944). `presentSessionError` de-duplicates, so the
                // two routes cannot raise two alerts for one failure.
                presentSessionError(backgroundService.sessionErrorToken)
                offerCaptureRecoveryIfNeeded()
                Task { await sharedImporter.drain() }
                // Offline captures upgrade when the path returns, and on every
                // foreground in case it returned while suspended (issue #999).
                OfflineTranscriptUpgrader.shared.startObservingNetwork()
                Task { await OfflineTranscriptUpgrader.shared.run() }
            }
            .onChange(of: scenePhase) { _, phase in
                // Scene intent is recorded synchronously so an owned utterance
                // finishes once through the controlled stop (issue #942).
                handsFree.sceneActivityChanged(isActive: phase == .active)
                if phase == .active {
                    refreshBackgroundState()
                    Task { await sharedImporter.drain() }
                    Task { await OfflineTranscriptUpgrader.shared.run() }
                }
            }
            .onChange(of: coordinator.state) { _, state in
                if let announcement = state.accessibilityAnnouncement {
                    AccessibilityNotification.Announcement(announcement).post()
                }
            }
            .onChange(of: backgroundService.isRunning) { wasRunning, isRunning in
                // A live background session just finished — surface its result
                // instead of leaving the screen blank.
                if wasRunning && !isRunning { refreshBackgroundState() }
            }
    }

    func sheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showingPostProcessing) {
                PostProcessingView(initialText: currentText) { processedResult in
                    displayText = processedResult
                }
            }
            .sheet(item: $issueReport) { IOSIssueReportPreview(controller: $0) }
            // Swiping the sheet away counts as finishing it, so first run is
            // offered exactly once and never nags. Auto-start is considered on
            // the way out, so enabling it before onboarding still takes effect
            // on this launch — the onboarding capture has already been stopped
            // by then, and `coordinator.start()` is single-flight regardless.
            .sheet(isPresented: $showingFirstRun, onDismiss: {
                onboarding.completeFirstRun()
                showingDiagnosticsConsent = DiagnosticsConsent.shared.needsDecision
                Task { await autoStartIfEnabled() }
            }, content: {
                FirstRunOnboardingView(
                    audioSessionManager: coordinator.audioSessionManager,
                    liveTranscript: coordinator.partialText,
                    startTestDictation: { try await coordinator.start() },
                    stopTestDictation: { await coordinator.stop().text },
                    onFinish: { showingFirstRun = false }
                )
            })
    }
}
#endif
