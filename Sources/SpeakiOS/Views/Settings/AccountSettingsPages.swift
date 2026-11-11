#if os(iOS)
import SpeakCore
import SpeakSync
import SwiftUI

struct PostProcessingSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SearchableSettingsSection("Post-Processing") {
            Toggle(isOn: $settings.autoPostProcess) {
                Label("Auto-Polish After Recording", systemImage: "wand.and.stars")
            }

            if settings.autoPostProcess {
                SettingsFootnote("Opens the polish view after each recording.")
            }

            NavigationLink {
                PostProcessingSettingsView(settings: settings)
            } label: {
                HStack {
                    Label("Model & Prompt", systemImage: "slider.horizontal.3")
                        .layoutPriority(1)
                    Spacer()
                    Text(postProcessingModelName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if settings.hasPostProcessingKey {
                SettingsFootnote("Polish tidies punctuation and wording with an AI model, using your prompt.")
            } else {
                Label(
                    "\(settings.postProcessingKeyProviderName) API key required",
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
                SettingsFootnote(
                    "**Add a \(settings.postProcessingKeyProviderName) key** in Providers & API Keys "
                        + "to polish transcripts.",
                    alwaysShown: true
                )
            }
        }
    }

    private var postProcessingModelName: String {
        let model = settings.postProcessingModel
        return ModelPickerGrouping.selectionLabel(
            for: model, displayName: ModelCatalog.friendlyName(for: model), purpose: .postProcessing
        )
    }
}

struct ProvidersSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Hidden while iOS paid routing is unwired — see `PaidAccessFeature`.
        // The screen stays compiled so re-enabling is one constant.
        if PaidAccessFeature.isAvailableOnIOS {
            SearchableSettingsSection("Subscription") {
                NavigationLink {
                    PaidAccessSettingsView()
                } label: {
                    HStack {
                        Label("Paid Access", systemImage: "creditcard")
                            .layoutPriority(1)
                        Spacer()
                        Text(PaidAccessStore.shared.entitlement.status.displayName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }

        SearchableSettingsSection("API Keys") {
            if settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
                NavigationLink {
                    APIKeysView(settings: settings)
                } label: {
                    compactAPIKeySummary
                }
            } else {
                apiKeyStatusRow(name: "Deepgram", systemImage: "waveform", isStored: settings.hasDeepgramKey)
                apiKeyStatusRow(
                    name: "ElevenLabs",
                    systemImage: "mic.and.signal.meter",
                    isStored: settings.hasElevenLabsKey
                )
                apiKeyStatusRow(name: "OpenRouter", systemImage: "network", isStored: settings.hasOpenRouterKey)
                apiKeyStatusRow(name: "OpenAI", systemImage: "brain.head.profile", isStored: settings.hasOpenAIKey)

                NavigationLink {
                    APIKeysView(settings: settings)
                } label: {
                    Label("Manage Keys", systemImage: "key.viewfinder")
                }
            }

            SettingsFootnote(
                "Remote models need their provider's key. **Tap Manage Keys to add one**, then choose "
                    + "the model in Transcription."
            )
        }
    }

    private var compactAPIKeySummary: some View {
        let entries = APIKeysView.entries(for: settings)
        let stored = entries.filter(\.isStored).count
        return HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label("Manage Keys", systemImage: "key.viewfinder")
            Spacer()
            Text("\(stored)/\(entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(stored == entries.count ? .green : .secondary)
        }
        .accessibilityLabel("\(stored) of \(entries.count) API keys stored. Manage keys.")
    }

    private func apiKeyStatusRow(name: String, systemImage: String, isStored: Bool) -> some View {
        HStack {
            Label(name, systemImage: systemImage)
                .accessibilityLabel("\(name) API Key")
            Spacer()
            Text(isStored ? "Stored" : "Missing")
                .foregroundStyle(isStored ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SyncSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    /// Observed so the status rows follow the iCloud History switch.
    @ObservedObject private var historySync = HistorySyncEngine.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SearchableSettingsSection("Sync") {
            CloudKitSyncSettingsSection()

            CloudKitKeySyncSettingsSection()

            // History remains local when its CloudKit lane is off/unavailable.
            // Protocol support below does not imply a shipping iPhone sender.
            let syncStatus = historySync.isSyncEnabled
                ? SyncStatus.current(iCloudCloudKitAvailable: historySync.state.isCloudAvailable)
                : SyncStatus()

            if settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
                compactSyncStatus(syncStatus)
            } else {
                syncStatusRows(syncStatus)
            }

            if let lastSync = syncStatus.lastSyncDate {
                LabeledContent("Last Sync") {
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                QRCodeGeneratorView()
            } label: {
                Label("Share to Another Device", systemImage: "qrcode")
            }

            NavigationLink {
                QRCodeScannerView()
            } label: {
                Label("Import from QR Code", systemImage: "qrcode.viewfinder")
            }

            SettingsFootnote(
                "History syncs through **iCloud** when it's on; otherwise it stays on this iPhone. "
                    + "Settings don't sync: use **Share to Another Device** to copy them. "
                    + "The iPhone app has no Bonjour transcript sender."
            )
        }
    }

    /// Display only: protocol support is not an iPhone History delivery lane.
    private func historySyncBackend(_ status: SyncStatus) -> SyncBackend {
        historySync.isSyncEnabled && status.iCloudCloudKitAvailable ? .iCloud : .localOnly
    }

    private func compactSyncStatus(_ status: SyncStatus) -> some View {
        HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label(historySyncBackend(status).displayName, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
            Spacer()
            // No iCloud Keychain or iCloud Settings icons: API keys never use
            // iCloud Keychain and no settings sync through iCloud. History and
            // encrypted key sync report their own status above.
            Image(systemName: status.transportAvailable ? "network" : "xmark.circle")
                .foregroundStyle(status.transportAvailable ? .green : .secondary)
                .accessibilityLabel(
                    "Bonjour protocol support: \(status.transportAvailable ? "included" : "not included")"
                )
        }
        .font(.caption)
    }

    private func syncStatusRows(_ status: SyncStatus) -> some View {
        Group {
            HStack {
                Label("History Sync", systemImage: "arrow.triangle.branch")
                Spacer()
                Text(historySyncBackend(status).displayName)
                    .foregroundStyle(historySyncBackend(status) != .localOnly ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)

            // iCloud History and Encrypted API-Key Sync rows sit above; there is
            // no iCloud Keychain or iCloud Settings path to report.
            HStack {
                Label("Bonjour Protocol", systemImage: "network")
                Spacer()
                Text(status.transportAvailable ? "Included" : "Not included")
                    .foregroundStyle(status.transportAvailable ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct PrivacyDiagnosticsSettingsPage: View {
    @State private var debugLogging = SpeakLogger.isDebugMode

    var body: some View {
        SearchableSettingsSection("Capture Health") {
            NavigationLink {
                CaptureHealthView()
            } label: {
                Label("Check capture is working", systemImage: "stethoscope")
            }
            .accessibilityIdentifier("captureHealthNavLink")

            SettingsFootnote(
                "**Start here if recording fails.** Checks permissions, runs a microphone self-test and "
                    + "recovers interrupted recordings. Nothing leaves this iPhone."
            )
        }

        SearchableSettingsSection("Privacy & Debugging") {
            NavigationLink {
                PrivacyView()
            } label: {
                Label("Privacy Information", systemImage: "hand.raised")
            }

            Toggle(isOn: Binding(
                get: { debugLogging },
                set: {
                    SpeakLogger.isDebugMode = $0
                    debugLogging = $0
                }
            )) {
                Label("Debug Logging", systemImage: "ant")
            }

            if debugLogging {
                SettingsFootnote("Logs extra detail for troubleshooting.")
            }
        }
    }
}

struct AboutSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SearchableSettingsSection("About") {
            if settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
                compactBuildSummary
            } else {
                LabeledContent("Version") {
                    Text("\(appVersion) (\(appBuild))")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Commit") {
                    Text(BuildInfo.gitCommitShort)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("SpeakCore") {
                    Text(SpeakCore.version)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                ReleaseNotesView()
            } label: {
                Label("Release Notes", systemImage: "sparkles")
            }
            .accessibilityHint("Shows what changed in this version and earlier versions")

            Link(destination: PrivacyPolicy.url) {
                Label("Privacy Policy", systemImage: "hand.raised.square")
            }
            .accessibilityIdentifier("privacyPolicyLink")
            .accessibilityHint("Opens the published privacy policy in your browser")
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appVersion: String { Self.appVersion }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var compactBuildSummary: some View {
        HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label("\(appVersion) (\(appBuild))", systemImage: "app.badge")
            Spacer()
            Text(BuildInfo.gitCommitShort)
                .font(.caption.monospaced())
            Text("Core \(SpeakCore.version)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
#endif
