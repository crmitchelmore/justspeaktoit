#if os(iOS)
import SwiftUI
import AVFoundation
import SpeakCore
import os.log

private let logger = SpeakLogger.logger(category: "RecordingsView")

// MARK: - Recordings List View

/// Shows all locally saved audio recordings with playback, delete, and
/// transcribe-again.
///
/// The transcribe-again action is what makes the saved audio worth keeping
/// (issue #992): a capture whose transcript never arrived — the network died,
/// the app was killed — still has its audio here, and this is where it is
/// turned back into text.
public struct RecordingsView: View {
    @Environment(\.appVisualDensity) private var density
    @State private var recordings: [RecordingInfo] = []
    @State private var playingURL: URL?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var showingDeleteConfirmation = false
    @State private var recordingToDelete: RecordingInfo?
    @State private var transcribing: UUID?
    @State private var transcribeMessage: String?

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
                            },
                            isTranscribing: transcribing == rec.id,
                            onTranscribe: { transcribeAgain(rec) }
                        )
                    }
                    if let transcribeMessage {
                        Text(transcribeMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        // List immediately (cheap directory scan), then fill in durations
        // asynchronously so a large library doesn't stall the main thread.
        let listed = AudioRecordingPersistence.listRecordings()
        recordings = listed
        Task { @MainActor in
            for rec in listed {
                let duration = await AudioRecordingPersistence.loadDuration(for: rec.url)
                guard duration > 0,
                      let index = recordings.firstIndex(where: { $0.id == rec.id })
                else { continue }
                recordings[index] = RecordingInfo(
                    id: rec.id,
                    url: rec.url,
                    startedAt: rec.startedAt,
                    duration: duration,
                    fileSize: rec.fileSize
                )
            }
        }
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
            logger.error("Playback error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingURL = nil
    }

    /// Turns a saved recording back into text and files it in History. The
    /// audio file is never touched, whether this succeeds or fails, so a
    /// failed attempt costs the user nothing (issue #992).
    private func transcribeAgain(_ rec: RecordingInfo) {
        guard transcribing == nil else { return }
        transcribing = rec.id
        transcribeMessage = nil
        Task {
            defer { transcribing = nil }
            do {
                let text = try await CaptureRecoveryCoordinator.transcribe(url: rec.url)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    transcribeMessage = "That recording produced no text. The audio is still here."
                    return
                }
                // A deliberate re-transcription is a new entry: the user asked
                // for it, possibly with a different model. Only the automatic
                // recovery path is keyed on the recording, so that retrying an
                // interrupted one cannot duplicate its row.
                iOSHistoryManager.shared.add(iOSHistoryItem(
                    createdAt: rec.startedAt,
                    transcription: trimmed,
                    model: CaptureRecoveryCoordinator.recoveryModel(),
                    duration: rec.duration,
                    wordCount: trimmed.split(whereSeparator: \.isWhitespace).count,
                    originPlatform: CaptureRecoveryCoordinator.recoveredOrigin
                ))
                // This recording may be the one an interrupted capture left
                // behind. Its transcript has just been delivered, so the
                // matching claim must close: otherwise the next recovery pass
                // offers the same audio again and accepting it duplicates the
                // History row (issue #992). Failed and empty attempts above
                // return before this and stay retryable.
                CaptureSafetyClaimStore.shared.forget(recording: rec.id)
                CaptureRecoveryCoordinator.shared.refresh()
                transcribeMessage = "Saved to History. The audio is still here."
            } catch {
                transcribeMessage = "Could not transcribe that recording. The audio is still here."
            }
        }
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
    let isTranscribing: Bool
    let onTranscribe: () -> Void

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
                .lineLimit(1)
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
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(action: onTranscribe) {
                Label("Transcribe", systemImage: "text.badge.plus")
            }
            .tint(.accentColor)
            .disabled(isTranscribing)
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
