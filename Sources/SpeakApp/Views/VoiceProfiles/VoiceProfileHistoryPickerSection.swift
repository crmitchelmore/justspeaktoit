import SpeakCore
import SwiftUI

/// Selects a History recording, runs portable VAD trimming to the cleanest 10-20s, and lets the user preview it.
struct VoiceProfileHistoryPickerSection: View {
    @ObservedObject var history: HistoryManager
    @ObservedObject var voiceProfiles: VoiceProfileManager
    let isAtClipLimit: Bool
    let onClipPrepared: (VoiceProfileStagedClip) -> Void

    @State private var selectedItemID: UUID?
    @State private var candidateClip: VoiceProfileStagedClip?
    @State private var preparationError: String?

    private var historyItemsWithAudio: [HistoryItem] {
        history.allItems.filter { item in
            guard let url = item.audioFileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if historyItemsWithAudio.isEmpty {
                Text("No local History recordings with saved audio were found on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a History recording. Voice activity detection trims it to the cleanest 10–20 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List(historyItemsWithAudio.prefix(30), selection: $selectedItemID) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(itemSummary(item))
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
                .frame(minHeight: 120, maxHeight: 160)
                .accessibilityLabel("History recordings with audio")
                .accessibilityIdentifier("voiceProfileHistoryList")
                .onChange(of: selectedItemID) { _, newValue in
                    prepareSelectedItem(id: newValue)
                }
            }

            if let preparationError {
                Text(preparationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let candidateClip {
                candidatePreview(candidateClip)
            }
        }
        .onDisappear {
            if let previewURL = candidateClip?.previewURL {
                try? FileManager.default.removeItem(at: previewURL)
            }
            candidateClip = nil
        }
    }

    private func candidatePreview(_ clip: VoiceProfileStagedClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = clip.trimSummary {
                Text(summary)
                    .font(.caption.weight(.medium))
            }
            if let previewURL = clip.previewURL {
                AudioPlaybackControls(url: previewURL)
            }
            if clip.qualityReport.passed {
                Text("Quality gate passed (SNR \(Int(clip.qualityReport.estimatedSNRDB.rounded())) dB).")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                ForEach(clip.qualityReport.rejectionReasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Button("Add Trimmed Clip") {
                let accepted = clip
                candidateClip = nil
                selectedItemID = nil
                onClipPrepared(accepted)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAtClipLimit)
            .accessibilityIdentifier("voiceProfileUseHistoryClipButton")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func itemSummary(_ item: HistoryItem) -> String {
        let text = (item.postProcessedTranscription ?? item.rawTranscription ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return String(format: "Recording (%.1f s)", item.recordingDuration)
    }

    private func prepareSelectedItem(id: UUID?) {
        if let previousURL = candidateClip?.previewURL {
            try? FileManager.default.removeItem(at: previousURL)
        }
        candidateClip = nil
        preparationError = nil
        guard let id, let item = historyItemsWithAudio.first(where: { $0.id == id }) else { return }
        do {
            candidateClip = try voiceProfiles.prepareClipFromHistory(item, targetFormat: .pcm24k)
        } catch {
            preparationError = error.localizedDescription
        }
    }
}
