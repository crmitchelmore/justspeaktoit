//
//  JustSpeakToItWidgetExtensionLiveActivity.swift
//  JustSpeakToItWidgetExtension
//
//  Created by Chris Mitchelmore on 09/01/2026.
//

import ActivityKit
import AppIntents
import WidgetKit
import SwiftUI
import SpeakCore
import SpeakiOSLib

private let brandAccent = Color(red: 1.0, green: 0.42, blue: 0.24)

struct JustSpeakToItWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranscriptionActivityAttributes.self) { context in
            // Lock Screen / Banner view
            LockScreenTranscriptionView(state: context.state, startTime: context.attributes.startTime)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        transcriptionStatusIndicator(for: context.state.status)
                        Text(context.state.provider)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DynamicIslandExpandedRegion(.center) {
                    if context.state.status == .completed {
                        Text("✓ \(context.state.wordCount) words copied to clipboard")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text(context.state.lastSnippet.isEmpty ? "Listening..." : context.state.lastSnippet)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(formatDuration(context.state.duration), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if context.state.status == .listening {
                            if #available(iOS 18, *) {
                                Button(intent: StopTranscriptionRecordingIntent()) {
                                    Label("Stop & Copy", systemImage: "stop.circle.fill")
                                        .font(.caption2)
                                }
                                .tint(.red)
                            }
                        } else if context.state.status == .completed {
                            Text("Copied ✓")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            } compactLeading: {
                transcriptionStatusIndicator(for: context.state.status)
            } compactTrailing: {
                if context.state.status == .listening {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                } else {
                    Text("\(context.state.wordCount)w")
                        .font(.caption2)
                }
            } minimal: {
                if context.state.status == .listening {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                } else {
                    transcriptionStatusIndicator(for: context.state.status)
                }
            }
        }
    }
}

// MARK: - Helpers

private func formatDuration(_ seconds: Int) -> String {
    let mins = seconds / 60
    let secs = seconds % 60
    return String(format: "%d:%02d", mins, secs)
}

// MARK: - Status Indicator

@ViewBuilder
private func transcriptionStatusIndicator(
    for status: TranscriptionActivityAttributes.TranscriptionStatus
) -> some View {
    switch status {
    case .listening:
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative.reversing)
            .foregroundStyle(.red)
    case .processing:
        Image(systemName: "ellipsis")
            .symbolEffect(.variableColor.iterative)
    case .paused:
        Image(systemName: "pause.fill")
            .foregroundStyle(.orange)
    case .error:
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
    case .completed:
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
    case .idle:
        Image(systemName: "mic.fill")
    }
}

// MARK: - Lock Screen View

struct LockScreenTranscriptionView: View {
    let state: TranscriptionActivityAttributes.ContentState
    let startTime: Date

    var body: some View {
        HStack(spacing: 12) {
            VStack {
                transcriptionStatusIndicator(for: state.status)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(state.provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(state.wordCount) words • ")
                        .font(.caption)
                        .foregroundStyle(.secondary) +
                    Text(startTime, style: .timer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if state.status == .completed {
                    Text("✓ \(state.wordCount) words copied to clipboard")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else if let error = state.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if state.lastSnippet.isEmpty {
                    Text("Listening...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(state.lastSnippet)
                        .font(.subheadline)
                        .lineLimit(2)
                }
            }

            if state.status == .listening {
                if #available(iOS 18, *) {
                    Button(intent: StopTranscriptionRecordingIntent()) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
    }
}

// MARK: - Preview

#Preview("Lock Screen", as: .content, using: TranscriptionActivityAttributes()) {
    JustSpeakToItWidgetExtensionLiveActivity()
} contentStates: {
    TranscriptionActivityAttributes.ContentState(
        status: .listening,
        lastSnippet: "The quick brown fox jumps over the lazy dog...",
        wordCount: 42,
        duration: 125,
        provider: "Apple Speech"
    )
    TranscriptionActivityAttributes.ContentState(
        status: .completed,
        lastSnippet: "Transcription complete",
        wordCount: 156,
        duration: 300,
        provider: "Deepgram"
    )
}
