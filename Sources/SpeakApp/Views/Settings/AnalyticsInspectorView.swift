#if !APP_STORE
import AppKit
import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

struct AnalyticsInspectorButton: View {
    let controls: AnalyticsPrivacyControls
    @State private var isPresented = false

    var body: some View {
        Button("Open Analytics Inspector") { isPresented = true }
            .sheet(isPresented: $isPresented) { AnalyticsInspectorView(controls: controls) }
    }
}

struct AnalyticsInspectorView: View {
    @ObservedObject var controls: AnalyticsPrivacyControls
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    init(controls: AnalyticsPrivacyControls, selection: UUID? = nil) {
        self.controls = controls
        self._selection = State(initialValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Analytics Inspector").font(.title2.bold())
                Spacer()
                if controls.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating analytics privacy controls")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Group {
                Text("Consent: \(consentLabel) · Collection: \(collectionLabel)")
                Text("Endpoint: \(controls.snapshot?.endpoint ?? "Loading…")")
                Text("Local identity: \(controls.installationID?.uuidString ?? "Not created")")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("Queue: \(controls.snapshot?.queueDepth ?? 0) events")
            }
            .font(.callout)
            Text(
                "Ingestion credential omitted. At most 100 events from this launch are shown; "
                    + "valid queued events survive relaunch. HTTP acknowledged means a 2xx response, "
                    + "not independently verified backend processing."
            )
            .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(records, selection: $selection) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.event).font(.callout.weight(.medium)).lineLimit(1).help(record.event)
                        Text(record.status.rawValue).font(.caption)
                        Text(record.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(record.id)
                }
                .frame(minWidth: 180, idealWidth: 210)
                ScrollView([.horizontal, .vertical]) {
                    Text(selectedRecord?.json ?? "Select an event to inspect its credential-free JSON.")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minWidth: 320)
            }
            .frame(minHeight: 220)
            HStack {
                Button(controls.policy.isLocallyDisabled ? "Clear local override" : "Disable collection on this Mac") {
                    Task { await controls.setDisabled(!controls.policy.isLocallyDisabled) }
                }
                .disabled(controls.isBusy || controls.policy.isBuildDisabled)
                Button("Reset local identity") { Task { await controls.resetIdentity() } }
                    .disabled(controls.isBusy)
                Button("Export…", action: export)
                    .disabled(controls.isBusy || controls.snapshot == nil)
            }
            if controls.policy.isBuildDisabled {
                Text("Collection is disabled by the build or launch policy. This cannot be cleared here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let feedback = controls.feedback { Text(feedback).font(.callout).textSelection(.enabled) }
            Text(
                "Disabling or resetting clears local queued and inspected events. "
                    + "Server records and exported files remain."
            )
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 500)
        .task {
            while !Task.isCancelled {
                await controls.refresh()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        .onChange(of: controls.snapshot?.records.map(\.id)) { _, identifiers in
            if let selection, identifiers?.contains(selection) != true { self.selection = nil }
        }
    }

    private var records: [AnalyticsInspectionRecord] { Array((controls.snapshot?.records ?? []).reversed()) }

    private var selectedRecord: AnalyticsInspectionRecord? {
        controls.snapshot?.records.first { $0.id == selection }
    }

    private var consentLabel: String {
        switch controls.consent {
        case .unknown: return "Not chosen"
        case .optedIn: return "Opted in"
        case .optedOut: return "Opted out"
        }
    }

    private var collectionLabel: String {
        guard let snapshot = controls.snapshot else { return "Loading…" }
        if snapshot.isDisabled { return "Locally disabled" }
        return snapshot.isOpen && controls.consent.permitsCollection ? "Enabled" : "Closed"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "analytics-inspection.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await controls.export(to: destination) }
    }
}
#endif
