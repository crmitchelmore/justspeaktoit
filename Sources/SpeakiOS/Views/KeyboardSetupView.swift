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
                    Text("Dictate in any app, right from the keyboard")
                        .font(.title2.bold())
                    Text(
                        "Tap the mic key and your words stream into the text field as you speak — "
                            + "no app switching. Use the globe key to return to the system keyboard for typing."
                    )
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("Setup") {
                setupStep(
                    number: 1,
                    title: "Add the keyboard",
                    detail: "Settings › General › Keyboard › Keyboards › Add New Keyboard › Just Speak."
                )
                setupStep(
                    number: 2,
                    title: "Allow Full Access",
                    detail: "Open Just Speak in the keyboard list and turn on Allow Full Access."
                )
                setupStep(
                    number: 3,
                    title: "Tap the mic and speak",
                    detail: "In any text field, hold the globe key, pick Just Speak, and tap the mic. "
                        + "Allow microphone and speech recognition when asked the first time."
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
                    "iOS does not tell apps which keyboards are enabled. "
                        + "These indicators update after the Just Speak keyboard has been opened once."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Fallback: Instant Dictation") {
                statusRow(
                    title: "App-owned microphone",
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
                    "Only needed if the keyboard can't record itself — for example if you declined its "
                        + "microphone or speech-recognition permission, your language has no speech "
                        + "recogniser, or in-keyboard capture fails. Just Speak then keeps a ready "
                        + "microphone session and the keyboard hands recording to the app — still without "
                        + "leaving the app you're typing in. Idle audio is discarded immediately and never "
                        + "saved or sent."
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
                Label(
                    "Lets the keyboard run the microphone and Apple speech recognition",
                    systemImage: "mic.fill"
                )
                Label(
                    "Shares your language choice and dictation state with the app",
                    systemImage: "gearshape.2"
                )
                Label(
                    "Required by iOS before a keyboard may record or reach the network",
                    systemImage: "lock.open"
                )
                Text(
                    "The keyboard reads the text just before the cursor only to place dictated words "
                        + "correctly, and never stores or transmits it. It records only while the mic key "
                        + "is active, prefers on-device Apple speech, and shares state with Just Speak "
                        + "solely through the private App Group."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Where It Won’t Appear") {
                limitation("Secure password fields", symbol: "lock.fill")
                limitation("Phone-pad fields", symbol: "phone.fill")
                limitation("Apps that disable third-party keyboards", symbol: "app.badge")
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
            return instantDictation.isEnabled ? "Needs reconnect" : "Off"
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
        // Keep the keyboard's language chip in sync with the app preference.
        KeyboardDictationPreferencesStore.shared.mirrorAppPreference(
            selectedIdentifier: AppSettings.shared.preferredLocaleIdentifier
        )
    }
}
#endif
