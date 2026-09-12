#if os(iOS)
import Foundation
import SpeakCore
import SwiftUI

// MARK: - Hardware Trigger Settings View

/// Configuration screen for the Action Button / Shortcuts / Siri / widget
/// recording entry points. Lets the user pick what happens to the transcript
/// when recording stops and explains how to wire each entry point.
struct HardwareTriggerSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("When Recording Stops") {
                Picker("Destination", selection: $settings.hardwareTriggerDestination) {
                    ForEach(HardwareTriggerDestination.allCases) { destination in
                        Text(destination.displayName)
                            .accessibilityIdentifier("hardwareTriggerDestination.\(destination.rawValue)")
                            .tag(destination)
                    }
                }
                .accessibilityIdentifier("hardwareTriggerDestinationPicker")
                .pickerStyle(.inline)
                .labelsHidden()

                Text(settings.hardwareTriggerDestination.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.hardwareTriggerDestination == .clipboardAndPostProcess
                    && !settings.hasOpenRouterKey {
                    Label(
                        "Add an OpenRouter API key under API Keys to enable polishing. "
                            + "Without it, polishing falls back to plain clipboard.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Clipboard Privacy") {
                Text(self.settings.transcriptClipboardPrivacySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Change this under Settings → Privacy Information → Clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            autoStopSection

            Section("Before You Start") {
                Text(
                    "Open JustSpeakToIt before first use and grant the requested permissions, "
                        + "including microphone access. You may need to unlock your iPhone or open the app "
                        + "to start recording."
                )
                    .font(.callout)
            }

            if #available(iOS 18.0, *) {
                nativeControlSetupSection
            }

            Section("Set Up a Shortcut") {
                Text(
                    "Toggle Recording requires iOS 18 or iPadOS 18 or later. Create one shortcut for the "
                        + "options below or for your existing automations. Back Tap on a supported iPhone and "
                        + "Apple Pencil Pro squeeze on a compatible iPad do not require an Action Button."
                )
                    .font(.callout)

                StepRow(number: 1, text: "Open the Shortcuts app and tap the + button.")
                StepRow(
                    number: 2,
                    text: "Search for JustSpeakToIt and add Toggle Recording as the only action. "
                        + "Do not add a separate Copy to Clipboard action — JustSpeakToIt uses the "
                        + "destination selected above when you stop. Use Start Recording only if you also "
                        + "create a separate Stop Recording shortcut."
                )
                StepRow(number: 3, text: "Name the shortcut and tap Done.")

                Button {
                    if let url = URL(string: "shortcuts://") {
                        openURL(url)
                    }
                } label: {
                    Label("Open Shortcuts App", systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("openShortcutsAppButton")

                NavigationLink {
                    AutomationGalleryView()
                } label: {
                    Label("Shortcuts Gallery", systemImage: "square.stack.3d.up")
                }
                .accessibilityIdentifier("hardwareTriggerGalleryLink")
            }

            Section("Other Trigger Options") {
                BulletRow(
                    icon: "button.programmable",
                    title: "Action Button Shortcut",
                    detail: "On an iPhone with an Action Button, open Settings → Action Button → Shortcut "
                        + "and choose your saved shortcut. Press and hold the Action Button to run it."
                )
                BulletRow(
                    icon: "mic.fill",
                    title: "Siri",
                    detail: "Say \"Toggle Recording with JustSpeakToIt\" or \"Start Recording with JustSpeakToIt\"."
                )
                BulletRow(
                    icon: "square.grid.2x2.fill",
                    title: "Home Screen Shortcuts Widget",
                    detail: "Add a Shortcuts widget to the Home Screen and pick your Toggle Recording shortcut."
                )
                BulletRow(
                    icon: "hand.tap.fill",
                    title: "Back Tap",
                    detail: "On a supported iPhone, open Settings → Accessibility → Touch → Back Tap → "
                        + "Double Tap or Triple Tap. Under Shortcuts, choose the shortcut saved above."
                )
                BulletRow(
                    icon: "applepencil",
                    title: "Apple Pencil Pro Squeeze",
                    detail: "On a compatible iPad with Apple Pencil Pro, open Settings → Apple Pencil → "
                        + "Squeeze → Shortcut and choose the shortcut saved above."
                )
                if let url = URL(string: "https://support.apple.com/guide/shortcuts/apdbe445a3a2/ios") {
                    Link("Apple Pencil Pro Shortcut Setup Guide", destination: url)
                }
            }

            Section("Try Your Shortcut") {
                Text(
                    "Every trigger uses the destination selected above; it is not a separate "
                        + "setting for each gesture."
                )
                    .font(.callout)
                StepRow(
                    number: 1,
                    text: "For your first test, keep the screen awake and the device unlocked. "
                        + "Run your assigned gesture, check that recording has started, then speak. "
                        + "Opening or unlocking the app may be required."
                )
                StepRow(
                    number: 2,
                    text: "Run the same gesture again to stop with Toggle Recording, or use the "
                        + "Live Activity stop control. Check History for the result."
                )
            }

            Section("What Runs") {
                Label("Live model: \(settings.selectedModel)", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "Recording uses the live model from the Transcription section above. "
                        + "If the chosen model needs an API key that isn't set, JustSpeakToIt "
                        + "falls back to Apple Speech (on-device) so the trigger still works."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Action Button & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Silence auto-stop (issue #1012). Deliberately explicit about the cost:
    /// somebody who thinks in long pauses needs to know this will cut them off
    /// before they turn it on, not after.
    private var autoStopSection: some View {
        Section("Stop On Silence") {
            Toggle("Finish after a pause", isOn: $settings.autoStopOnSilenceEnabled)
                .accessibilityIdentifier("autoStopOnSilenceToggle")

            Text(
                "Recordings started from a Control, the Action Button, Siri or a Shortcut finish "
                    + "on their own once you stop speaking, so one press is the whole capture. "
                    + "Recordings you start in the app or from the keyboard are unaffected."
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.autoStopOnSilenceEnabled {
                Stepper(
                    "Pause length: \(settings.autoStopSilenceSeconds, specifier: "%.0f")s",
                    value: $settings.autoStopSilenceSeconds,
                    in: CaptureEndPointingPolicy.silenceWindowRange,
                    step: 1
                )
                    .accessibilityIdentifier("autoStopSilenceStepper")

                Text(
                    "Shorter finishes sooner but is likelier to cut you off while you are thinking. "
                        + "A recording that never goes quiet still stops after "
                        + "\(Int(CaptureEndPointingPolicy.defaultMaximumDurationSeconds / 60)) minutes."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @available(iOS 18.0, *)
    private var nativeControlSetupSection: some View {
        Section("Set Up Transcribe Voice") {
            Text("On iOS 18 and later, add JustSpeakToIt’s Transcribe Voice control directly.")
                .font(.callout)
            BulletRow(
                icon: "button.programmable",
                title: "Action Button",
                detail: "On an iPhone with an Action Button, open Settings → Action Button → Controls. "
                    + "Tap the control picker and choose Transcribe Voice. Press and hold the Action Button "
                    + "to start or stop dictation."
            )
            BulletRow(
                icon: "square.grid.2x2.fill",
                title: "Control Center",
                detail: "Open Control Center, tap the + at the top left, then tap Add a Control. "
                    + "Find JustSpeakToIt and choose Transcribe Voice."
            )
            BulletRow(
                icon: "lock.iphone",
                title: "Lock Screen Control",
                detail: "Touch and hold the Lock Screen, unlock if asked, then tap Customise → Lock Screen. "
                    + "Remove a bottom control with the minus button, tap the + in that slot, and choose "
                    + "Transcribe Voice. Tap Done. This is a bottom control, separate from the widgets below the clock."
            )
        }
    }
}

private struct StepRow: View {
    @ScaledMetric(relativeTo: .headline) private var badgeSize = 24.0
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: badgeSize, height: badgeSize)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BulletRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
