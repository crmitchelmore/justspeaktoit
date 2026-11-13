#if os(iOS)
import AVFoundation
import Speech
import SpeakCore
import SwiftUI

/// The Troubleshooting page (issue #1634): what stops dictation on this
/// device, worst first, each with the action that fixes it. The rules live in
/// `MobileTroubleshooting` so Android reaches the same verdicts.
struct IOSTroubleshootingView: View {
    enum Destination: Hashable {
        case apiKeys, transcription, keyboard
    }

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.iOSKeyboardEnabled) private var keyboardOffered
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var findings: [MobileTroubleshooting.Finding]?
    @State private var rejectedKeyIdentifiers: Set<String> = []
    @State private var verifying: MobileTroubleshooting.Check?
    @State private var verificationMessage: String?
    @State private var destination: Destination?

    var body: some View {
        Form {
            summarySection
            if let findings {
                Section("Checks") {
                    ForEach(findings) { finding in
                        IOSTroubleshootingRow(
                            finding: finding, isVerifying: verifying == finding.check
                        ) { fix in
                            Task { await perform(fix, for: finding.check) }
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    CaptureHealthView()
                } label: {
                    Label("Check capture is working", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("troubleshooting.captureHealthLink")
            } footer: {
                Text("Capture Health tests the microphone and recovers interrupted recordings.")
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .apiKeys: APIKeysView(settings: settings)
            case .transcription: IOSSettingsPageView(page: .transcription)
            case .keyboard: KeyboardSetupView()
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onChange(of: destination) { _, newValue in
            if newValue == nil { Task { await refresh() } }
        }
        .alert(
            "Key check",
            isPresented: Binding(
                get: { verificationMessage != nil },
                set: { if !$0 { verificationMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("troubleshooting.keyCheckDismiss")
        } message: {
            Text(verificationMessage ?? "")
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if let findings {
                let overall = MobileTroubleshooting.overall(findings)
                Label(Self.summary(overall), systemImage: IOSTroubleshootingRow.icon(overall))
                    .foregroundStyle(IOSTroubleshootingRow.tint(overall))
                    .accessibilityIdentifier("troubleshooting.summary")
            } else {
                HStack {
                    ProgressView()
                    Text("Checking…").foregroundStyle(.secondary)
                }
            }
        }
    }

    static func summary(_ severity: MobileTroubleshooting.Severity) -> String {
        switch severity {
        case .issue: return "Something is stopping dictation."
        case .warning: return "Dictation should work, with something worth fixing."
        case .info, .ok: return "Everything dictation needs is in place."
        }
    }

    private func refresh() async {
        let input = await IOSTroubleshootingProbe.gather(
            settings: settings, keyboardOffered: keyboardOffered,
            rejectedKeyIdentifiers: rejectedKeyIdentifiers
        )
        findings = MobileTroubleshooting.findings(input)
    }

    private func perform(_ fix: MobileTroubleshooting.Fix, for check: MobileTroubleshooting.Check) async {
        switch fix {
        case .requestMicrophone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .requestSpeechRecognition:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .openSystemSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        case .openAPIKeys:
            destination = .apiKeys
            return
        case .openTranscriptionSettings:
            destination = .transcription
            return
        case .openKeyboardSetup:
            destination = .keyboard
            return
        case .disablePostProcessing:
            settings.postProcessingEnabled = false
        case .verifyKey:
            await verifyKey(for: check)
        }
        await refresh()
    }

    private func verifyKey(for check: MobileTroubleshooting.Check) async {
        guard let target = IOSTroubleshootingProbe.verificationTarget(for: check, settings: settings) else { return }
        verifying = check
        defer { verifying = nil }
        let writer = APIKeyCredentialWriter(settings: settings)
        if await writer.validationFailure(of: target.key, for: target.entryID) != nil {
            rejectedKeyIdentifiers.insert(target.identifier)
            verificationMessage = "✗ \(target.providerName) did not accept the saved key. Replace it in API keys."
        } else {
            rejectedKeyIdentifiers.remove(target.identifier)
            verificationMessage = "✓ \(target.providerName) accepted the saved key."
        }
    }
}

struct IOSTroubleshootingRow: View {
    let finding: MobileTroubleshooting.Finding
    let isVerifying: Bool
    let perform: (MobileTroubleshooting.Fix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.icon(finding.severity))
                    .foregroundStyle(Self.tint(finding.severity))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Label(finding.title, systemImage: finding.systemImage)
                        .font(.body.weight(.medium))
                    Text(finding.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Self.severityLabel(finding.severity)): \(finding.title). \(finding.detail)")
            .accessibilityIdentifier("troubleshooting.\(finding.check.rawValue)")

            if !finding.fixes.isEmpty {
                HStack {
                    ForEach(finding.fixes, id: \.self) { fix in
                        Button(fix.title) { perform(fix) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isVerifying)
                            .accessibilityIdentifier("troubleshooting.\(finding.check.rawValue).\(fix.rawValue)")
                    }
                    if isVerifying { ProgressView() }
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func icon(_ severity: MobileTroubleshooting.Severity) -> String {
        switch severity {
        case .issue: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .ok: return "checkmark.circle.fill"
        }
    }

    static func tint(_ severity: MobileTroubleshooting.Severity) -> Color {
        switch severity {
        case .issue: return .red
        case .warning: return .orange
        case .info: return .blue
        case .ok: return .green
        }
    }

    static func severityLabel(_ severity: MobileTroubleshooting.Severity) -> String {
        switch severity {
        case .issue: return "Problem"
        case .warning: return "Warning"
        case .info: return "Note"
        case .ok: return "OK"
        }
    }
}
#endif
