import AppKit
import SpeakCore
import SwiftUI

// MARK: - Step Views

struct WelcomeStepView: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: AppIconProvider.applicationIcon())
                .resizable()
                .frame(width: 100, height: 100)

            Text(ReleaseTrain.current.displayName)
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Voice transcription that types for you")
                .font(.title3)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "mic.fill", title: "Speak naturally", description: "Record with a hotkey, speak normally"
                )
                FeatureRow(
                    icon: "keyboard.fill", title: "Text appears instantly",
                    description: "Transcription is typed into any app"
                )
                FeatureRow(
                    icon: "key.fill", title: "Your keys, your privacy",
                    description: "Bring your own API keys - no data collection"
                )
            }
            .padding(.top, 20)
            .padding(.horizontal, 40)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct PermissionsStepView: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        ScrollView {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("App Permissions")
                .font(.title)
                .fontWeight(.bold)

            Text("\(RunningAppIdentity.current.name) needs a few permissions to work")
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                PermissionRow(
                    type: .microphone,
                    title: "Microphone",
                    description: "To hear your voice",
                    isGranted: state.permissionsGranted.contains(.microphone),
                    onRequest: {
                        Task {
                            _ = await state.permissionsManager.requestWithGuidance(.microphone)
                            state.refreshPermissions()
                        }
                    }
                )

                if DistributionChannel.current.supportsAccessibilityTextInsertion {
                    PermissionRow(
                        type: .accessibility,
                        title: "Accessibility",
                        description: "To type text into other apps",
                        isGranted: state.permissionsGranted.contains(.accessibility),
                        onRequest: {
                            Task {
                                _ = await state.permissionsManager.requestWithGuidance(.accessibility)
                                state.refreshPermissions()
                            }
                        }
                    )
                }

                PermissionRow(
                    type: .inputMonitoring,
                    title: "Input Monitoring",
                    description: "For the Fn hotkey while using other apps",
                    isGranted: state.permissionsGranted.contains(.inputMonitoring),
                    isOptional: true,
                    onRequest: {
                        Task {
                            _ = await state.permissionsManager.requestWithGuidance(.inputMonitoring)
                            state.refreshPermissions()
                        }
                    }
                )
            }
            .padding(.horizontal, 40)
            .padding(.top, 10)

            PermissionRecoveryHelp(permissions: state.permissionsManager)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        }
        .task {
            // Accessibility and Input Monitoring are granted in System Settings
            // and the OS never notifies us, so poll while this step is on screen
            // to reflect the grants live instead of forcing an app restart. The
            // loop is automatically cancelled when the view disappears.
            while !Task.isCancelled {
                state.refreshPermissions()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

struct PermissionRow: View {
    let type: PermissionType
    let title: String
    let description: String
    let isGranted: Bool
    var isOptional = false
    let onRequest: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline)
                    if isOptional {
                        Text("(Optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            } else {
                Button("Grant") {
                    onRequest()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("onboardingGrantPermissionButton-\(String(describing: type))")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}
