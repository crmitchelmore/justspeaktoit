#if os(iOS)
import SpeakCore
import SwiftUI
import UIKit

public struct KeyboardSetupView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var observation: KeyboardExtensionObservation?
    @ObservedObject private var instantDictation = KeyboardInstantDictationCoordinator.shared

    public init() {}

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Speak into any supported text field")
                        .font(.title2.bold())
                    Text(
                        "Just Speak is a transcription-first keyboard. Use its globe button "
                            + "to return to the system keyboard for normal typing."
                    )
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("Setup") {
                setupStep(
                    number: 1,
                    title: "Add Just Speak",
                    detail: "In Settings, go to General › Keyboard › Keyboards › Add New Keyboard."
                )
                setupStep(
                    number: 2,
                    title: "Allow Full Access",
                    detail: "Open Just Speak in the keyboard list and turn on Allow Full Access."
                )
                setupStep(
                    number: 3,
                    title: "Enable Instant Dictation once",
                    detail: "Return here and enable the always-ready microphone session. Idle audio is discarded."
                )
                setupStep(
                    number: 4,
                    title: "Choose it in a text field",
                    detail: "Touch and hold the globe key, select Just Speak, and begin speaking."
                )

                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    Label("Open iOS Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("openKeyboardSettingsButton")
            }

            Section("Observed Status") {
                statusRow(
                    title: "Keyboard opened",
                    isReady: observation != nil,
                    readyText: observation.map { "Seen \($0.lastSeenAt.formatted(.relative(presentation: .named)))" }
                        ?? "Not yet observed"
                )
                statusRow(
                    title: "Full Access",
                    isReady: observation?.hadFullAccess == true,
                    readyText: fullAccessStatus
                )
                Text(
                    "iOS does not provide the containing app with a complete keyboard-enabled status API. "
                        + "These indicators update after the Just Speak keyboard has been opened."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Instant Dictation") {
                statusRow(
                    title: "Keyboard microphone",
                    isReady: instantDictation.isReady || instantDictation.isRecording,
                    readyText: instantDictationStatus
                )

                Button {
                    if instantDictation.session == nil {
                        Task {
                            await instantDictation.startSession()
                        }
                    } else {
                        instantDictation.endSession()
                    }
                } label: {
                    Label(
                        instantDictationButtonTitle,
                        systemImage: instantDictation.session == nil ? "mic.badge.plus" : "stop.circle"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(instantDictation.session == nil ? .accentColor : .red)
                .accessibilityIdentifier("keyboardInstantDictationButton")

                Text(
                    "Enable once, then opening the Just Speak keyboard starts transcription automatically. "
                        + "The orange microphone indicator stays visible while Instant Dictation is ready. "
                        + "Idle audio is discarded immediately on device and is never saved or sent."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let errorMessage = instantDictation.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Why Full Access?") {
                Label("Start transcription as soon as the keyboard appears", systemImage: "mic.fill")
                Label("Bind each result to its original text document", systemImage: "scope")
                Label("Use cloud transcription only when your selected model requires it", systemImage: "network")
                Text(
                    "iOS does not give keyboard extensions microphone access. Just Speak owns the explicit, "
                        + "user-enabled audio session while the keyboard sends only nonce-scoped commands. "
                        + "It does not read, persist, or transmit surrounding text."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Where It Won’t Appear") {
                limitation("Secure password fields", symbol: "lock.fill")
                limitation("Phone-pad fields", symbol: "phone.fill")
                limitation("Apps that disable third-party keyboards", symbol: "app.badge")
            }

            Section("What to Expect") {
                Text(
                    "After setup, focus any supported text field and choose Just Speak. Recording starts "
                        + "automatically; tap Stop to insert the final text at that field's cursor."
                )
                Text(
                    "After an iPhone restart, force quit, or audio interruption, open Just Speak once to reconnect."
                )
                .foregroundStyle(.secondary)
                Text(
                    "Local Apple Speech can work offline after its language resources are available. "
                        + "Cloud models need a network connection and the provider key configured in Just Speak."
                )
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Just Speak Keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refresh()
            }
        }
    }

    private var fullAccessStatus: String {
        guard let observation else { return "Open the keyboard to check" }
        return observation.hadFullAccess ? "Observed on" : "Observed off"
    }

    private var instantDictationStatus: String {
        guard let session = instantDictation.session,
              instantDictation.isReady || instantDictation.isRecording else {
            return instantDictation.isEnabled ? "Needs reconnect" : "Not enabled"
        }
        if session.phase == .recording { return "Recording" }
        return "Ready until turned off"
    }

    private var instantDictationButtonTitle: String {
        if instantDictation.session != nil {
            return "Turn Off Instant Dictation"
        }
        return instantDictation.isEnabled ? "Reconnect Now" : "Enable Instant Dictation"
    }

    private func setupStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.tint, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title). \(detail)")
    }

    private func statusRow(title: String, isReady: Bool, readyText: String) -> some View {
        HStack {
            Label(title, systemImage: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isReady ? .green : .secondary)
            Spacer()
            Text(readyText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func limitation(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(.secondary)
    }

    private func refresh() {
        observation = KeyboardHandoffStore.shared.extensionObservation()
    }
}
#endif
