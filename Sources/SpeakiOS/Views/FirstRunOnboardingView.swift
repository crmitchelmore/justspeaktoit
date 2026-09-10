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

    @State private var microphoneGranted: Bool?
    @State private var speechGranted: Bool?
    @State private var isRequestingPermissions = false
    @State private var isRecording = false
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
                }
            }
            .interactiveDismissDisabled(isRecording)
        }
        .task { refreshPermissionStatus() }
        .onDisappear { countdown?.cancel() }
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
            .disabled(!permissionsGranted)
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

    // MARK: - Actions

    private func refreshPermissionStatus() {
        microphoneGranted = audioSessionManager.hasMicrophonePermission() ? true : nil
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
        if isRecording {
            await stopTest()
        } else {
            await startTest()
        }
    }

    private func startTest() async {
        failureMessage = nil
        testTranscript = ""
        secondsRemaining = Int(CaptureOnboardingPolicy.testDictationLimit)
        do {
            try await startTestDictation()
        } catch {
            failureMessage = error.localizedDescription
            return
        }
        isRecording = true
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
        guard isRecording else { return }
        countdown?.cancel()
        countdown = nil
        isRecording = false
        let text = await stopTestDictation()
        testTranscript = text
        if !CaptureOnboardingPolicy.isProvenTranscript(text) {
            failureMessage = "No words came back. Check the microphone and try again."
        }
    }

    /// Primes the Live Activity so the first headless trigger can update an
    /// existing activity instead of asking the user to continue in the app,
    /// then records that first run is over.
    private func finish() {
        countdown?.cancel()
        countdown = nil
        if permissionsGranted, AppSettings.shared.liveActivitiesEnabled {
            TranscriptionActivityManager.shared.startActivity(
                provider: "Ready to record",
                initialStatus: .idle
            )
        }
        onFinish()
    }
}
#endif
