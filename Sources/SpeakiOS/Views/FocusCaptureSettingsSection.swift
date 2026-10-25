#if os(iOS)
import SpeakCore
import SwiftUI

/// Reports the last native receipt, not an inferred Focus name or authorization status.
struct FocusCaptureSettingsSection: View {
    @State private var summary = "No stored Focus override"
    @State private var failure: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section("Focus Capture Overrides") {
            Text(summary)
                .accessibilityIdentifier("focusCaptureOverrideStatus")
            Text("In Settings > Focus > Add Filter, choose Capture Overrides for Action Button, Siri and Shortcuts. "
                 + "The in-app microphone and keyboard profiles keep their own settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset Stored Override") {
                do {
                    try FocusCaptureOverrideStore.live().write(.none)
                    refresh()
                } catch { failure = error.localizedDescription }
            }
            .accessibilityIdentifier("resetFocusCaptureOverride")
            Text("Reset clears this app's stored selection. An active system Focus filter can apply it again "
                 + "at the next capture; remove or change that filter in Settings to stop using it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure).foregroundStyle(.orange)
            }
        }
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        do {
            let snapshot = try FocusCaptureOverrideStore.live().snapshot()
            if snapshot.invalidReason != nil {
                summary = "Stored Focus choice needs correction"
            } else if snapshot.override.isEmpty {
                summary = "No stored Focus override"
            } else {
                var fields: [String] = []
                let destination = snapshot.override.destinationID.flatMap { HardwareTriggerDestination(rawValue: $0) }
                if let destination {
                    fields.append(destination.displayName)
                }
                if snapshot.override.modelID != nil { fields.append("Model override") }
                if snapshot.override.languageIdentifier != nil { fields.append("Language override") }
                summary = "Last received: " + fields.joined(separator: " · ")
            }
            failure = nil
        } catch {
            summary = "Stored Focus override unavailable"
            failure = error.localizedDescription
        }
    }
}
#endif
