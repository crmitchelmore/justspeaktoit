import SpeakCore
import SpeakSync
import SwiftUI

/// This Mac's iCloud data sync switch. One switch covers History and Compare
/// Models results, the two stores that sync without a separate opt-in;
/// Encrypted API-Key Sync keeps its own card. Off means no CloudKit traffic
/// for either store, so both stay on this Mac.
struct ICloudSyncSettingsCard: View {
  @ObservedObject private var historySync = HistorySyncEngine.shared

  var body: some View {
    SettingsCard(title: "iCloud Sync", systemImage: "icloud", tint: Color.brandLagoon) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle(
          "Sync History and comparisons with iCloud",
          isOn: Binding(
            get: { historySync.isSyncEnabled },
            set: { newValue in setSyncEnabled(newValue) }
          )
        )
        .tint(Color.brandLagoon)
        .settingsControlChrome()
        .accessibilityIdentifier("iCloudDataSyncToggle")

        Text(historySync.isSyncEnabled ? Self.onCaption : Self.offCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .speakTooltip("Choose whether History and Compare Models results sync through your private iCloud database.")
  }

  private func setSyncEnabled(_ enabled: Bool) {
    historySync.setSyncEnabled(enabled)
    // Comparisons read the same stored switch; a pass now picks them up
    // rather than waiting for the adapter's periodic retry.
    if enabled {
      Task { await ComparisonSyncEngine.shared.sync() }
    }
  }

  private static let onCaption =
    "History, including transcript text, and Compare Models results sync to your private CloudKit "
    + "database while this Mac is signed in to iCloud. Transcripts from your iPhone also arrive this way."

  private static let offCaption =
    "History and Compare Models results stay on this Mac, and transcripts from your iPhone no longer "
    + "arrive through iCloud. Anything already in iCloud stays there. Turning sync back on uploads what "
    + "was saved while it was off."
}
