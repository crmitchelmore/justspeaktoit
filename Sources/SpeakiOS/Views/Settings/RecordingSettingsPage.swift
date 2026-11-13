#if os(iOS)
import SpeakCore
import SwiftUI

struct RecordingSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.iOSKeyboardEnabled) private var iOSKeyboardEnabled

    var body: some View {
        SearchableSettingsSection("Hardware Trigger") {
            NavigationLink {
                HardwareTriggerSettingsView(settings: settings)
            } label: {
                HStack {
                    Label("Action Button & Shortcuts", systemImage: "button.programmable")
                        .layoutPriority(1)
                    Spacer()
                    Text(settings.hardwareTriggerDestination.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityIdentifier("hardwareTriggerSettingsLink")

            NavigationLink {
                AutomationGalleryView()
            } label: {
                Label("Shortcuts Gallery", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("automationGalleryLink")

            SettingsFootnote(
                "**Recommended:** set the **Action Button** to the **Transcribe Voice** control. "
                    + "Press once to start and again to stop. Siri, Control Center and Back Tap work too."
            )
        }

        SearchableSettingsSection("Behavior") {
            Toggle(isOn: $settings.autoStartRecording) {
                Label("Auto-Start Recording", systemImage: "mic.badge.plus")
            }

            if settings.autoStartRecording {
                SettingsFootnote("Recording starts as soon as you open the app.")
            }

            Toggle(isOn: $settings.handsFreeDictationEnabled) {
                Label("Hands-Free Dictation", systemImage: "waveform.badge.mic")
            }
            .disabled(!settings.handsFreeDictationSupported)
            .accessibilityIdentifier("handsFreeDictationToggle")

            SettingsFootnote(handsFreeDictationCaption)

            Toggle(isOn: $settings.liveActivitiesEnabled) {
                Label("Live Activities", systemImage: "platter.filled.bottom.iphone")
            }

            if settings.liveActivitiesEnabled {
                SettingsFootnote("Shows progress \(DeviceCopy.liveActivityPlacement).")
            }
        }

        if iOSKeyboardEnabled {
            SearchableSettingsSection("Just Speak Keyboard") {
                NavigationLink {
                    KeyboardSetupView()
                } label: {
                    HStack {
                        Label("Set Up Keyboard", systemImage: "keyboard")
                        Spacer()
                        Text(keyboardStatusLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("keyboardSetupLink")

                SettingsFootnote("Transcribe into other apps through a private handoff to Just Speak.")
            }
        }

        FocusCaptureSettingsSection()
    }

    /// Matches the macOS wording; the silence budget lives in the shared policy.
    private var handsFreeDictationCaption: String {
        guard settings.handsFreeDictationSupported else {
            return "Requires iOS 26 or later — Apple's on-device speech detector isn't available here."
        }
        return "**Arm it from the microphone button.** The microphone stays on while armed; "
            + "silent audio stays in memory and never leaves \(DeviceCopy.thisDevice)."
    }

    private var keyboardStatusLabel: String {
        guard let observation = KeyboardHandoffStore.shared.extensionObservation() else {
            return "Not observed"
        }
        return observation.hadFullAccess ? "Full Access on" : "Full Access off"
    }
}

struct ResultsSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var changingTranscriptReadyNotifications = false
    @State private var transcriptReadyPermissionDenied = false

    var body: some View {
        SearchableSettingsSection("Saved Results") {
            Toggle(isOn: Binding(
                get: { self.settings.transcriptReadyNotificationsEnabled },
                set: { enabled in
                    self.changingTranscriptReadyNotifications = true
                    Task { @MainActor in
                        let allowed = await TranscriptReadyNotificationCoordinator.shared
                            .setEnabledFromUser(enabled)
                        self.transcriptReadyPermissionDenied = enabled && !allowed
                        self.changingTranscriptReadyNotifications = false
                    }
                }
            )) {
                Label("Transcript Ready Alerts", systemImage: "bell")
            }
            .disabled(self.changingTranscriptReadyNotifications)
            .accessibilityIdentifier("transcriptReadyNotificationsToggle")
            SettingsFootnote(
                "Alerts for results saved in the background. They never include the transcript.",
                alwaysShown: true
            )
            if self.transcriptReadyPermissionDenied {
                SettingsFootnote(
                    "Alerts are off. **Allow notifications** for Just Speak in iOS Settings, then turn this on.",
                    alwaysShown: true
                )
            }
            Toggle(isOn: $settings.upgradeOfflineTranscriptsWhenOnline) {
                Label("Upgrade offline transcripts when back online", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("upgradeOfflineTranscriptsToggle")
            SettingsFootnote(
                "Re-transcribes offline on-device recordings with your cloud model once you're online. "
                    + "**Uses provider credit.** Edited transcripts are never replaced.",
                alwaysShown: true
            )
        }

        SearchableSettingsSection("Recordings") {
            NavigationLink {
                RecordingsView()
            } label: {
                Label("Saved Recordings", systemImage: "waveform.circle")
            }

            Toggle(isOn: $settings.keepAudioOnCancel) {
                Label("Keep Audio When Cancelled", systemImage: "xmark.bin")
            }
            .accessibilityIdentifier("keepAudioOnCancelToggle")

            SettingsFootnote(
                settings.keepAudioOnCancel
                    ? "Cancelled recordings stay in **Saved Recordings** so you can transcribe them later."
                    : "Cancelling a recording deletes its audio."
            )
            SettingsFootnote(
                "Audio is kept on \(DeviceCopy.thisDevice) so you can replay it, "
                    + "or transcribe it again after a lost connection."
            )
        }
    }
}
#endif
