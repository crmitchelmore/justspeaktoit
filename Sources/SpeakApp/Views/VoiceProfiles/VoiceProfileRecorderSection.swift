import SpeakCore
import SwiftUI

/// Guided ~15-second prompt recording controls with live input level and clipping meters.
struct VoiceProfileRecorderSection: View {
    @ObservedObject var recorder: VoiceProfileRecorder
    @ObservedObject var voiceProfiles: VoiceProfileManager
    let isAtClipLimit: Bool
    let onClipCaptured: (VoiceProfileStagedClip) -> Void

    @State private var selectedScriptID = VoiceProfilePromptCatalog.scripts[0].id
    @State private var activeCaptureScriptText: String?
    @State private var statusMessage: String?

    private var selectedScript: VoiceProfilePromptScript {
        VoiceProfilePromptCatalog.scripts.first { $0.id == selectedScriptID }
            ?? VoiceProfilePromptCatalog.defaultScript()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Prompt Script", selection: $selectedScriptID) {
                ForEach(VoiceProfilePromptCatalog.scripts) { script in
                    Text(script.title).tag(script.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(recorder.isStarting || recorder.isRecording)
            .accessibilityIdentifier("voiceProfilePromptScriptPicker")

            VStack(alignment: .leading, spacing: 6) {
                Text("Read these sentences aloud at a natural pace:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(selectedScript.sentences.enumerated()), id: \.offset) { _, sentence in
                    Text(sentence)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            levelMeterView

            HStack(spacing: 12) {
                Button {
                    Task { await toggleRecording() }
                } label: {
                    Label(
                        recorder.isRecording ? "Stop Recording" : "Record Sample",
                        systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .brandAccent)
                .disabled(recorder.isStarting || (!recorder.isRecording && isAtClipLimit))
                .accessibilityLabel(recorder.isRecording ? "Stop voice sample recording" : "Record voice sample")
                .accessibilityValue(recorder.isRecording ? "Recording" : "Idle")
                .accessibilityAddTraits(recorder.isRecording ? .isButton : [.isButton, .startsMediaSession])
                .accessibilityIdentifier("voiceProfileRecordButton")

                if recorder.isStarting || recorder.isRecording {
                    Button("Cancel Recording", role: .cancel) {
                        activeCaptureScriptText = nil
                        Task { await recorder.cancelRecording() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("voiceProfileCancelRecordButton")
                }

                Spacer()

                Text(formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Recorded duration: \(formattedDuration)")
            }

            if let error = recorder.errorMessage ?? statusMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(recorder.errorMessage != nil ? .red : .secondary)
            }
        }
    }

    private var levelMeterView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input Level")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(String(format: "%.0f dBFS", recorder.peakDecibels))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(clippingStatusText)
                    .font(.caption.weight(recorder.isClipping ? .semibold : .regular))
                    .foregroundStyle(recorder.isClipping ? .red : .secondary)
            }

            ProgressView(value: Double(recorder.level), total: 1.0)
                .tint(recorder.isClipping ? .red : .green)
                .accessibilityLabel("Microphone input level")
                .accessibilityValue(
                    "\(Int((recorder.level * 100).rounded())) percent, \(clippingStatusText)"
                )
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("voiceProfileLevelMeter")
        }
    }

    private var clippingStatusText: String {
        if recorder.isClipping {
            return "Clipping detected — move slightly back from mic"
        }
        return recorder.isRecording ? "Level good" : "Ready"
    }

    private var formattedDuration: String {
        let elapsed = Int(recorder.elapsedSeconds.rounded(.down))
        let maxDuration = Int(VoiceProfile.maximumClipDuration)
        return String(format: "%02d:%02d / %02d:%02d", elapsed / 60, elapsed % 60, maxDuration / 60, maxDuration % 60)
    }

    private func toggleRecording() async {
        statusMessage = nil
        if recorder.isRecording {
            let scriptText = activeCaptureScriptText ?? selectedScript.fullText
            activeCaptureScriptText = nil
            if let buffer = await recorder.stopRecording(targetFormat: .pcm24k) {
                let staged = voiceProfiles.stageRecordedClip(buffer, transcript: scriptText)
                onClipCaptured(staged)
            }
            return
        }
        let scriptText = selectedScript.fullText
        activeCaptureScriptText = scriptText
        do {
            try await recorder.startRecording { buffer in
                activeCaptureScriptText = nil
                let staged = voiceProfiles.stageRecordedClip(buffer, transcript: scriptText)
                onClipCaptured(staged)
            }
        } catch is CancellationError {
            activeCaptureScriptText = nil
        } catch {
            activeCaptureScriptText = nil
            statusMessage = error.localizedDescription
        }
    }
}
