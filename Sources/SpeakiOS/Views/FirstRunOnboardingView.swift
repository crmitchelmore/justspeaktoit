#if os(iOS)
import Speech
import SpeakCore
import SwiftUI
import UIKit

/// The one-time first-run sheet: ask for microphone and speech up front so the
/// first hardware trigger cannot fail with an opaque background error, then
/// prove the whole path works with a short test dictation.
///
/// The sheet is deliberately skippable. Skipping leaves the existing lazy
/// permission requests in `iOSLiveTranscriber.ensurePermissions()` untouched,
/// so a user who dismisses it still gets prompted at record time exactly as
/// before.
struct FirstRunOnboardingView: View {
    let audioSessionManager: AudioSessionManager
    /// Live partial text from the recorder, so the test step shows words
    /// appearing rather than a spinner.
    let liveTranscript: String
    let startTestDictation: () async throws -> Void
    let stopTestDictation: () async -> String
    let onFinish: () -> Void

    /// The test dictation is a three-state toggle, not a boolean. `starting`
    /// exists because the coordinator start is asynchronous: without it a
    /// second tap (or a Skip) arriving mid-start would be read as "not
    /// recording" and could either spawn a second session or stop nothing and
    /// leave the started one capturing.
    private enum TestPhase {
        case idle
        case starting
        /// A teardown arrived while startup was still in flight. `startTest`
        /// stops the session it just created rather than leaving it live.
        case stoppingAfterStart
        case recording
    }

    @State private var microphoneGranted: Bool?
    @State private var speechGranted: Bool?
    @State private var isRequestingPermissions = false
    @State private var phase: TestPhase = .idle
    @State private var testTranscript = ""
    @State private var secondsRemaining = Int(CaptureOnboardingPolicy.testDictationLimit)
    @State private var failureMessage: String?
    @State private var countdown: Task<Void, Never>?

    private var permissionsGranted: Bool {
        microphoneGranted == true && speechGranted == true
    }

    private var permissionsDenied: Bool {
        microphoneGranted == false || speechGranted == false
    }

    private var testPassed: Bool {
        CaptureOnboardingPolicy.isProvenTranscript(testTranscript)
    }

    /// True from the moment a start is requested until the capture has been
    /// stopped, so nothing releases the sheet while a microphone may be live.
    private var testIsActive: Bool { phase != .idle }

    private var isRecording: Bool { phase == .recording }

    /// A start is in flight, so there is nothing stoppable yet.
    private var isSettlingStartup: Bool { phase == .starting || phase == .stoppingAfterStart }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Ready in about 20 seconds")
                            .font(.title2.bold())
                        Text(
                            "Grant access once here and every trigger — the app, a Control, a shortcut or the "
                                + "keyboard — works the first time you press it."
                        )
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                permissionSection
                testDictationSection
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(testPassed ? "Done" : "Skip") { finish() }
                        .accessibilityIdentifier("firstRunFinishButton")
                        // Finishing stops the capture first; the button stays
                        // out of reach only while startup itself is in flight,
                        // where there is nothing stoppable yet.
                        .disabled(isSettlingStartup)
                }
            }
            .interactiveDismissDisabled(testIsActive)
        }
        .task { refreshPermissionStatus() }
        // Returning from iOS Settings with access newly granted must clear the
        // Settings-only recovery path rather than leaving the test disabled.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onDisappear { stopTestOnTeardown() }
    }

    // MARK: - Steps

    @ViewBuilder
    private var permissionSection: some View {
        Section("1. Allow the microphone") {
            statusRow(title: "Microphone", granted: microphoneGranted)
            statusRow(title: "Speech recognition", granted: speechGranted)

            if permissionsDenied {
                Text("Access was declined. Turn it on in Settings, then come back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open iOS Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            } else if !permissionsGranted {
                Button {
                    Task { await requestPermissions() }
                } label: {
                    Label("Allow Access", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequestingPermissions)
                .accessibilityIdentifier("firstRunAllowAccessButton")
            }
        }
    }

    @ViewBuilder
    private var testDictationSection: some View {
        Section("2. Try it once") {
            Text(
                isRecording
                    ? "Say anything — it stops on its own in \(secondsRemaining)s."
                    : "A short test dictation proves the microphone, the model and the transcript all work."
            )
            .font(.callout)

            if isRecording, !liveTranscript.isEmpty {
                Text(liveTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if testPassed {
                Label(testTranscript, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("firstRunTestTranscript")
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await toggleTestDictation() }
            } label: {
                Label(
                    isRecording ? "Stop" : (testPassed ? "Try Again" : "Start Test Dictation"),
                    systemImage: isRecording ? "stop.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!permissionsGranted || isSettlingStartup)
            .accessibilityIdentifier("firstRunTestDictationButton")
        }
    }

    private func statusRow(title: String, granted: Bool?) -> some View {
        HStack {
            Text(title)
            Spacer()
            switch granted {
            case true:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            default:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// The actions live in an extension so the view body and the actions can
// each be read on their own; SwiftUI treats them identically.
@MainActor
private extension FirstRunOnboardingView {
    // MARK: - Actions

    private func refreshPermissionStatus() {
        if audioSessionManager.hasMicrophonePermission() {
            microphoneGranted = true
        } else if microphoneGranted != false {
            // A refused request is remembered; "not granted yet" stays unknown.
            microphoneGranted = nil
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechGranted = true
        case .denied, .restricted: speechGranted = false
        default: speechGranted = nil
        }
    }

    private func requestPermissions() async {
        isRequestingPermissions = true
        defer { isRequestingPermissions = false }

        if microphoneGranted != true {
            microphoneGranted = await audioSessionManager.requestMicrophonePermission()
        }
        guard microphoneGranted == true else { return }
        if speechGranted != true {
            speechGranted = await CancellablePermissionRequest.request { completion in
                SFSpeechRecognizer.requestAuthorization { completion($0 == .authorized) }
            }
        }
    }

    private func toggleTestDictation() async {
        switch phase {
        case .idle:
            await startTest()
        case .recording:
            await stopTest()
        case .starting, .stoppingAfterStart:
            // A start is already in flight and owns the toggle. The coordinator
            // refuses an overlapping start anyway; this keeps the UI honest
            // rather than relying on that alone.
            break
        }
    }

    private func startTest() async {
        guard phase == .idle else { return }
        failureMessage = nil
        testTranscript = ""
        secondsRemaining = Int(CaptureOnboardingPolicy.testDictationLimit)
        // Claim the toggle before the await: a second tap during startup must
        // not be read as "not recording".
        phase = .starting
        do {
            try await startTestDictation()
        } catch {
            let wasTornDown = phase == .stoppingAfterStart
            phase = .idle
            if !wasTornDown { failureMessage = error.localizedDescription }
            return
        }
        if phase == .stoppingAfterStart {
            // The sheet was dismissed while startup was in flight. The session
            // exists now, so this is the only place that can release it.
            phase = .idle
            _ = await stopTestDictation()
            return
        }
        phase = .recording
        countdown = Task {
            for remaining in stride(from: secondsRemaining - 1, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                secondsRemaining = remaining
            }
            await stopTest()
        }
    }

    private func stopTest() async {
        guard phase == .recording else { return }
        countdown?.cancel()
        countdown = nil
        phase = .idle
        let text = await stopTestDictation()
        testTranscript = text
        if !CaptureOnboardingPolicy.isProvenTranscript(text) {
            failureMessage = "No words came back. Check the microphone and try again."
        }
    }

    /// Stops the test capture if one is running and reports whether the caller
    /// had to wait for it. Used by every path that ends the sheet, so the
    /// microphone can never outlive the UI that started it.
    private func stopTestIfActive() async {
        countdown?.cancel()
        countdown = nil
        switch phase {
        case .idle, .stoppingAfterStart:
            return
        case .recording:
            phase = .idle
            _ = await stopTestDictation()
        case .starting:
            // Startup has not returned, so there may be no session to stop yet.
            // Hand the stop to `startTest`, which resumes owning it.
            phase = .stoppingAfterStart
        }
    }

    /// Any dismissal route other than the toolbar button — a programmatic
    /// dismissal, or a swipe once the capture has ended — still has to release
    /// the microphone.
    private func stopTestOnTeardown() {
        guard phase != .idle else {
            countdown?.cancel()
            countdown = nil
            return
        }
        Task { await stopTestIfActive() }
    }

    /// Primes the Live Activity so the first headless trigger can update an
    /// existing activity instead of asking the user to continue in the app,
    /// then records that first run is over. The test capture is stopped first:
    /// the sheet is never released while its recording is still live.
    private func finish() {
        countdown?.cancel()
        countdown = nil
        Task {
            await stopTestIfActive()
            if permissionsGranted, AppSettings.shared.liveActivitiesEnabled {
                TranscriptionActivityManager.shared.startActivity(
                    provider: "Ready to record",
                    initialStatus: .idle
                )
            }
            onFinish()
        }
    }
}
#endif
