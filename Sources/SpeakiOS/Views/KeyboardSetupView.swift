#if os(iOS)
import SpeakCore
import SwiftUI
import UIKit

public struct KeyboardSetupView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var observation: KeyboardExtensionObservation?
    @ObservedObject private var quickDictation = KeyboardQuickDictationCoordinator.shared

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
                    title: "Choose it in a text field",
                    detail: "Touch and hold the globe key, then select Just Speak."
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

            Section("Quick Dictation") {
                statusRow(
                    title: "Keyboard microphone",
                    isReady: quickDictation.isReady || quickDictation.isRecording,
                    readyText: quickDictationStatus
                )

                Button {
                    if quickDictation.session == nil {
                        Task {
                            await quickDictation.startSession()
                        }
                    } else {
                        quickDictation.endSession()
                    }
                } label: {
                    Label(
                        quickDictation.session == nil ? "Enable for 5 Minutes" : "End Quick Dictation",
                        systemImage: quickDictation.session == nil ? "mic.badge.plus" : "stop.circle"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(quickDictation.session == nil ? .accentColor : .red)
                .accessibilityIdentifier("keyboardQuickDictationButton")

                Text(
                    "Start once, return to your text field, then use Speak and Finish directly in the keyboard. "
                        + "The orange microphone indicator stays visible during this short session. "
                        + "Idle audio is discarded immediately on device and is never saved or sent."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let errorMessage = quickDictation.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Why Full Access?") {
                Label("Control a prepared microphone session from the keyboard", systemImage: "mic.fill")
                Label("Exchange one nonce-scoped result through the App Group", systemImage: "lock.shield")
                Label("Use cloud transcription only when your selected model requires it", systemImage: "network")
                Text(
                    "iOS does not give keyboard extensions microphone access. Just Speak owns the explicit, "
                        + "time-limited audio session while the keyboard sends only nonce-scoped commands. "
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
                    "Enable Quick Dictation here once, return to the original app, then start and finish "
                        + "future dictations inside the keyboard until the five-minute session expires."
                )
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

    private var quickDictationStatus: String {
        guard let session = quickDictation.session else { return "Not enabled" }
        if session.phase == .recording { return "Recording" }
        return "Ready until \(session.expiresAt.formatted(date: .omitted, time: .shortened))"
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
