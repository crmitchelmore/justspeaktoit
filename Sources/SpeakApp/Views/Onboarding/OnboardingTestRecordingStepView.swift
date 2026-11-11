import AppKit
import AVFoundation
import SpeakCore
import SwiftUI

// MARK: - Test Recording Step

struct TestRecordingStepView: View {
    @ObservedObject var state: OnboardingState
    @State private var audioPlayer: AVAudioPlayer?
    @State private var recordingURL: URL?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)

            Text("Test Your Setup")
                .font(.title)
                .fontWeight(.bold)

            Text("Record a short phrase to verify everything works")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                // Hotkey reminder
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.accentColor)
                    Text("Press **\(state.selectedHotKey.displayString)** to record, or use the button below")
                        .font(.subheadline)
                }
                .padding()
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)

                // Record button
                Button {
                    Task {
                        if state.isTestRecording {
                            await stopTestRecording()
                        } else {
                            await startTestRecording()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: state.isTestRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                        Text(state.isTestRecording ? "Stop Recording" : "Start Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(state.isTestRecording ? Color.red : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)

                // Results
                if let text = state.testRecordingText {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Transcription successful!")
                                .font(.headline)
                                .foregroundColor(.green)
                        }

                        Text(text)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)

                        // Playback button
                        if recordingURL != nil {
                            Button {
                                togglePlayback()
                            } label: {
                                HStack {
                                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                    Text(isPlaying ? "Stop Playback" : "Play Recording")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 40)
                }

                if let error = state.testRecordingError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 40)
                }
            }

            Text("You can skip this step and test later")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onDisappear {
            // Stop recording and playback if active when navigating away
            if state.isTestRecording {
                Task {
                    try? await state.audioFileManager.stopRecording()
                    state.isTestRecording = false
                }
            }
            audioPlayer?.stop()
            isPlaying = false
        }
    }

    private func startTestRecording() async {
        guard !state.isTestRecording else { return }
        state.testRecordingError = nil
        state.testRecordingText = nil
        state.isTestRecording = true
        do {
            let recording = try await state.audioFileManager.startRecording()
            recordingURL = recording.url
        } catch {
            state.isTestRecording = false
            state.testRecordingError = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func stopTestRecording() async {
        do {
            let summary = try await state.audioFileManager.stopRecording()
            state.isTestRecording = false
            recordingURL = summary.url

            // Transcribe the recording
            let result = try await state.transcriptionManager.transcribeFile(at: summary.url)
            if result.text.isEmpty {
                state.testRecordingError = "No speech detected. Try speaking louder or check your microphone."
            } else {
                state.testRecordingText = result.text
            }
        } catch {
            state.isTestRecording = false
            state.testRecordingError = "Transcription failed: \(error.localizedDescription)"
        }
    }

    private func togglePlayback() {
        if isPlaying {
            audioPlayer?.stop()
            isPlaying = false
        } else if let url = recordingURL {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.play()
                isPlaying = true

                // Poll to reset isPlaying when audio finishes naturally
                Task {
                    while isPlaying, let player = audioPlayer {
                        if !player.isPlaying {
                            isPlaying = false
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    }
                }
            } catch {
                state.testRecordingError = "Failed to play recording: \(error.localizedDescription)"
            }
        }
    }
}
