#if os(iOS)
import SpeakCore
import SwiftUI

// MARK: - Privacy View

struct PrivacyView: View {
    /// Both settings objects are observed so the "right now" section re-renders
    /// the moment a model, post-processing toggle or voice is changed elsewhere.
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var openClaw = OpenClawSettings.shared

    /// The user's effective workflow, projected from the live settings.
    private var summary: PrivacyWorkflowSummary {
        PrivacyWorkflowSummary.make(settings: settings, voiceOutput: openClaw)
    }

    private var transcriptionProviders: [LiveTranscriptionProviderID] {
        LiveTranscriptionRouting.iOSSupportedProviders
    }

    private func processingDescription(for provider: LiveTranscriptionProviderID) -> String {
        if provider == .apple {
            return "Microphone audio is transcribed on-device when supported; Apple's speech service may otherwise "
                + "process it on its servers."
        }
        return "Microphone audio is streamed to \(provider.displayName) for transcription."
    }

    var body: some View {
        Form {
            currentWorkflowSection
            supportedProvidersSection
            apiKeysSection
            networkActivitySection
            notCollectedSection
            permissionsSection
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var currentWorkflowSection: some View {
        Section("What happens with your recordings right now") {
            ForEach(summary.rows) { row in
                PrivacyWorkflowRow(row: row)
            }

            Text(
                summary.activeRecipients.isEmpty
                    ? "With your current settings nothing is sent to a cloud provider."
                    : "With your current settings your content can be sent to "
                        + PrivacyWorkflowSummary.formattedList(summary.activeRecipients) + "."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var supportedProvidersSection: some View {
        Section("Supported Providers (reference)") {
            Text("These are every provider this app can use, not what your current settings use.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(transcriptionProviders, id: \.self) { provider in
                FeatureRow(
                    icon: provider == .apple ? "mic.fill" : "network",
                    title: provider == .apple ? "Apple Speech" : provider.displayName,
                    description: processingDescription(for: provider)
                )
            }

            Text(PrivacyWorkflowSummary.textDisclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var apiKeysSection: some View {
        Section("API Keys") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Secure Storage", systemImage: "lock.fill")
                    .font(.headline)
                // swiftlint:disable:next line_length
                Text("API keys are encrypted in your device Keychain and never leave your device except when syncing via iCloud Keychain (end-to-end encrypted).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var networkActivitySection: some View {
        Section("Network Activity") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(transcriptionProviders, id: \.self) { provider in
                    InfoRow(
                        label: provider == .apple ? "Apple Speech" : provider.displayName,
                        value: provider == .apple ? "On-device when supported" : "During transcription"
                    )
                }
                ForEach(PrivacyWorkflowSummary.voiceOutputRecipients, id: \.self) { provider in
                    InfoRow(label: provider, value: "During voice output")
                }
                InfoRow(label: "Send to Mac", value: "Local network only")
                InfoRow(label: "iCloud Sync", value: "Settings & keys (optional)")
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var notCollectedSection: some View {
        Section("What We Don't Collect") {
            VStack(alignment: .leading, spacing: 8) {
                CheckRow(text: "No usage analytics")
                CheckRow(text: "No personal information")
                CheckRow(text: "No transcription content")
                CheckRow(text: "No third-party tracking")
            }
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        Section("Permissions") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speak requires these permissions:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PermissionRow(icon: "mic.fill", name: "Microphone", required: true)
                PermissionRow(icon: "waveform", name: "Speech Recognition", required: true)
                PermissionRow(icon: "network", name: "Local Network", required: false)
            }
        }
    }
}

/// One step of the user's effective workflow: what is sent, and where it goes.
struct PrivacyWorkflowRow: View {
    let row: PrivacyWorkflowSummary.Row

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.title3)
                .foregroundStyle(row.destination.leavesDevice ? Color.orange : Color.green)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(row.destinationLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(row.destination.leavesDevice ? Color.orange : .secondary)
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title). \(row.destinationLabel). \(row.detail)")
    }
}

#Preview("Privacy") {
    NavigationStack {
        PrivacyView()
    }
}

#endif
