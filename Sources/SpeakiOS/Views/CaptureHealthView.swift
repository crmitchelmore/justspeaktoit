#if os(iOS)
import SpeakCore
import SwiftUI

/// The Capture Health pane (issue #997).
///
/// Every row carries a badge saying what kind of evidence it is — *Tested*,
/// *Setting* or *Recorded* — because the difference between "the switch is on"
/// and "I just did this and it worked" is the difference between a screen that
/// helps and a screen that lies. The verdicts themselves are decided by
/// ``CaptureHealthReport`` in SpeakCore, where `swift test` proves each one.
///
/// There is deliberately no "send report" button. What this screen shows is a
/// content-free allowlist that never leaves the device, and adding a way to
/// ship it somewhere is issue #776's work, with issue #776's consent.
public struct CaptureHealthView: View {
    @StateObject private var recovery = CaptureRecoveryCoordinator.shared
    @State private var report: CaptureHealthReport?
    @State private var isGathering = false
    @State private var isSelfTesting = false
    @State private var selfTest: CaptureSelfTestResult?

    public init() {}

    public var body: some View {
        Form {
            self.summarySection
            self.checksSection
            self.selfTestSection
            if !self.recovery.recoverable.isEmpty || !self.recovery.uncertain.isEmpty {
                self.recoverySection
            }
            self.privacySection
        }
        .navigationTitle("Capture Health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await self.gather() }
        .refreshable { await self.gather() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if let report {
                HStack {
                    Image(systemName: Self.icon(for: report.overall))
                        .foregroundStyle(Self.tint(for: report.overall))
                    Text(Self.summary(for: report))
                }
                .accessibilityIdentifier("captureHealthSummary")
            } else {
                HStack {
                    ProgressView()
                    Text("Checking…").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var checksSection: some View {
        if let report {
            Section("Checks") {
                ForEach(report.checks) { check in
                    CaptureHealthRow(check: check)
                }
            }
            Section {
                ForEach(CaptureHealthEvidence.allCases, id: \.self) { evidence in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(evidence.label).font(.caption).bold()
                        Text(evidence.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What the badges mean")
            }
        }
    }

    @ViewBuilder
    private var selfTestSection: some View {
        Section("Microphone self-test") {
            Button {
                Task { await self.runSelfTest() }
            } label: {
                HStack {
                    Label("Run the self-test", systemImage: "waveform.badge.magnifyingglass")
                    Spacer()
                    if self.isSelfTesting { ProgressView() }
                }
            }
            .disabled(self.isSelfTesting)
            .accessibilityIdentifier("captureHealthSelfTestButton")

            Text(
                "Opens the microphone for up to two seconds and counts the audio it receives, then closes it. "
                    + "You do not need to speak: a microphone that is working delivers audio in a silent room. "
                    + "It writes nothing to History, does not touch the clipboard, and starts no Live Activity."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let selfTest {
                DisclosureGroup("What this test cannot tell you") {
                    ForEach(selfTest.limits, id: \.self) { limit in
                        Text("• " + limit.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        Section("Interrupted recordings") {
            ForEach(self.recovery.recoverable, id: \.run) { finding in
                CaptureRecoveryRow(finding: finding, coordinator: self.recovery)
            }
            ForEach(self.recovery.uncertain, id: \.run) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("Kept in Saved Recordings. Nothing was deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = self.recovery.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            Text(
                "Everything on this screen is worked out on this device and stays here. "
                    + "It contains no transcript, no keys, and no device or audio-route names, "
                    + "and there is no way to send it anywhere."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Work

    private func gather() async {
        guard !self.isGathering else { return }
        self.isGathering = true
        defer { self.isGathering = false }
        let probe = await CaptureHealthProbeRunner.gather(selfTest: self.selfTest)
        self.report = CaptureHealthReport.build(from: probe)
    }

    private func runSelfTest() async {
        self.isSelfTesting = true
        defer { self.isSelfTesting = false }
        self.selfTest = await CaptureSelfTestRunner().run()
        await self.gather()
    }

    // MARK: - Presentation

    static func summary(for report: CaptureHealthReport) -> String {
        switch report.overall {
        case .healthy: return "Everything checked here is working."
        case .attention: return "\(report.problems.count) thing(s) worth looking at."
        case .broken: return "\(report.problems.count) thing(s) will stop a capture working."
        case .undetermined, .notApplicable: return "Some checks have not been established yet."
        }
    }

    static func icon(for status: CaptureHealthStatus) -> String {
        switch status {
        case .healthy: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .broken: return "xmark.circle.fill"
        case .undetermined: return "questionmark.circle"
        case .notApplicable: return "minus.circle"
        }
    }

    static func tint(for status: CaptureHealthStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .attention: return .orange
        case .broken: return .red
        case .undetermined, .notApplicable: return .secondary
        }
    }
}

struct CaptureHealthRow: View {
    let check: CaptureHealthCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: CaptureHealthView.icon(for: self.check.status))
                .foregroundStyle(CaptureHealthView.tint(for: self.check.status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(self.check.title)
                    Text(self.check.evidence.label)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text(self.check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("captureHealth.\(self.check.id.rawValue)")
    }
}

struct CaptureRecoveryRow: View {
    let finding: CaptureRecoveryFinding
    @ObservedObject var coordinator: CaptureRecoveryCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.coordinator.promptMessage(for: self.finding))
                .font(.subheadline)
            HStack {
                Button("Transcribe") {
                    Task { await self.coordinator.recover(self.finding) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.coordinator.recovering != nil)

                Button("Keep audio") {
                    self.coordinator.keepWithoutTranscribing(self.finding)
                }
                .buttonStyle(.bordered)
                .disabled(self.coordinator.recovering != nil)

                if self.coordinator.recovering == self.finding.run { ProgressView() }
            }
            Text("Keeping leaves the audio in Saved Recordings. Nothing here deletes a recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("captureRecoveryRow")
    }
}
#endif
