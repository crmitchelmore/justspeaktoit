import SpeakCore
import SwiftUI

/// Displays one staged clip with playback preview, quality checks and editable transcript.
struct VoiceProfileStagedClipCard: View {
    let clip: VoiceProfileStagedClip
    let index: Int
    @Binding var transcript: String
    let isTranscribing: Bool
    let disableAutoFill: Bool
    let onAutoFill: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let durationText = String(format: "%.1f s", clip.pcmBuffer.durationSeconds)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clip \(index + 1) · \(clip.source.displayName) · \(durationText)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove clip \(index + 1)")
                .accessibilityIdentifier("voiceProfileRemoveClip-\(clip.id)")
            }

            if let summary = clip.trimSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let previewURL = clip.previewURL {
                AudioPlaybackControls(url: previewURL)
            }

            qualityStatusView

            HStack {
                Text("Transcript")
                    .font(.caption.weight(.medium))
                Spacer()
                Button(isTranscribing ? "Transcribing…" : "Auto-fill Transcript", action: onAutoFill)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(disableAutoFill)
                    .accessibilityIdentifier("voiceProfileAutoFillTranscript-\(clip.id)")
            }

            TextEditor(text: $transcript)
                .font(.body)
                .frame(minHeight: 54, maxHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
                .accessibilityLabel("Transcript for clip \(index + 1)")
                .accessibilityIdentifier("voiceProfileClipTranscript-\(clip.id)")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var qualityStatusView: some View {
        if clip.qualityReport.passed {
            Text(String(format: "Quality check passed (SNR %.0f dB)", clip.qualityReport.estimatedSNRDB))
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            ForEach(clip.qualityReport.rejectionReasons, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
