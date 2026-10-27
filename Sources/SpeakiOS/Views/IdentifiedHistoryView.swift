#if os(iOS)
import SwiftUI

/// Resolves only the requested saved row. Missing/deleted IDs never open latest.
struct IdentifiedHistoryView: View {
    let identifier: UUID
    @ObservedObject private var history = iOSHistoryManager.shared

    var body: some View {
        Group {
            if !self.history.isStorageReady {
                ContentUnavailableView("History unavailable", systemImage: "lock")
            } else if let item = TranscriptReadyNotificationRoute.savedItem(
                identifier: self.identifier, items: self.history.items
            ) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(item.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(item.transcription).textSelection(.enabled)
                        if let polished = item.postProcessedTranscription,
                           !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                            Text("Polished").font(.headline)
                            Text(polished).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            } else {
                ContentUnavailableView("Transcript is no longer available", systemImage: "clock.arrow.circlepath")
            }
        }
        .navigationTitle("History")
        .task { await self.history.loadIfNeededAndWait() }
    }
}
#endif
