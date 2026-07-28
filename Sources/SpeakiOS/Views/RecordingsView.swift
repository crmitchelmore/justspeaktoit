#if os(iOS)
import SwiftUI
import AVFoundation
import SpeakCore

// MARK: - Recordings List View

/// Shows all locally saved audio recordings with playback,
/// delete, and re-transcribe support.
public struct RecordingsView: View {
    @Environment(\.appVisualDensity) private var density
    @State private var recordings: [RecordingInfo] = []
    @State private var playingURL: URL?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var showingDeleteConfirmation = false
    @State private var recordingToDelete: RecordingInfo?

    public init() {}

    public var body: some View {
        Group {
            if recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform.slash")
                } description: {
                    Text(
                        "Audio recordings are saved automatically "
                            + "during transcription sessions."
                    )
                }
            } else {
                List {
                    Section {
                        Text(
                            "\(recordings.count) recording\(recordings.count == 1 ? "" : "s") "
                                + "· \(formattedTotalSize)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                    }

                    ForEach(recordings) { rec in
                        RecordingRow(
                            recording: rec,
                            isPlaying: playingURL == rec.url,
                            onPlay: { togglePlayback(rec) },
                            onDelete: {
                                recordingToDelete = rec
                                showingDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .environment(\.defaultMinListRowHeight, density.minimumListRowHeight)
        .listSectionSpacing(density.listSectionSpacing)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onDisappear { stopPlayback() }
        .confirmationDialog(
            "Delete Recording?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete {
                    delete(rec)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let rec = recordingToDelete {
                Text(
                    "This will permanently delete the "
                        + "\(formattedDuration(rec.duration)) recording."
                )
            }
        }
    }

    // MARK: - Computed

    private var formattedTotalSize: String {
        let total = recordings.reduce(0) { $0 + $1.fileSize }
        return ByteCountFormatter.string(
            fromByteCount: total,
            countStyle: .file
        )
    }

    // MARK: - Actions

    private func reload() {
        recordings = AudioRecordingPersistence.listRecordings()
    }

    private func togglePlayback(_ rec: RecordingInfo) {
        if playingURL == rec.url {
            stopPlayback()
            return
        }

        stopPlayback()

        do {
            let player = try AVAudioPlayer(contentsOf: rec.url)
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            playingURL = rec.url

            // Monitor completion
            Task { @MainActor in
                while audioPlayer?.isPlaying == true {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if playingURL == rec.url {
                    playingURL = nil
                }
            }
        } catch {
            print("[RecordingsView] Playback error: \(error)")
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingURL = nil
    }

    private func delete(_ rec: RecordingInfo) {
        if playingURL == rec.url {
            stopPlayback()
        }
        AudioRecordingPersistence.deleteRecording(at: rec.url)
        recordings.removeAll { $0.id == rec.id }
    }
}

// MARK: - Recording Row

struct RecordingRow: View {
    @Environment(\.appVisualDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let recording: RecordingInfo
    let isPlaying: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: density.isCompact ? 6 : 12) {
            // Play/Stop button
            Button(action: onPlay) {
                Image(
                    systemName: isPlaying
                        ? "stop.circle.fill"
                        : "play.circle.fill"
                )
                .font(.system(size: density.isCompact ? 24 : 32))
                .foregroundStyle(
                    isPlaying ? .red : Color.accentColor
                )
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel(
                isPlaying ? "Stop playback" : "Play recording"
            )

            if usesInlineDensityLayout {
                HStack(spacing: 4) {
                    Text(recording.startedAt, format: .dateTime.month(.abbreviated).day())
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(recording.startedAt, style: .time)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(formattedDuration(recording.duration))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: recording.fileSize,
                            countStyle: .file
                        )
                    )
                    .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.startedAt, style: .date)
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 8) {
                        Text(recording.startedAt, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(formattedDuration(recording.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: recording.fileSize,
                                countStyle: .file
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(.vertical, density.listRowVerticalPadding)
        .frame(minHeight: density.minimumListRowHeight)
    }

    private var usesInlineDensityLayout: Bool {
        density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
    }
}

// MARK: - Helpers

func formattedDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    if minutes > 0 {
        return "\(minutes)m \(seconds)s"
    }
    return "\(seconds)s"
}

#Preview {
    NavigationStack {
        RecordingsView()
    }
}
#endif
