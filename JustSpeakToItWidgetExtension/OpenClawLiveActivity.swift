//
//  OpenClawLiveActivity.swift
//  JustSpeakToItWidgetExtension
//

import ActivityKit
import SwiftUI
import WidgetKit
import SpeakiOSLib

private let brandAccent = Color(red: 1.0, green: 0.42, blue: 0.24)

struct OpenClawLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OpenClawActivityAttributes.self) { context in
            // Lock Screen / Banner view
            OpenClawLockScreenView(
                state: context.state,
                startTime: context.attributes.startTime
            )
            .widgetURL(URL(string: "justspeaktoit://openclaw"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        openClawStatusIndicator(for: context.state.status)
                        Text("OpenClaw")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.messageCount) msgs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(formatDuration(context.state.duration), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(context.state.status.rawValue.capitalized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                openClawStatusIndicator(for: context.state.status)
            } compactTrailing: {
                Text("\(context.state.messageCount)")
                    .font(.caption2)
            } minimal: {
                openClawStatusIndicator(for: context.state.status)
            }
            .widgetURL(URL(string: "justspeaktoit://openclaw"))
        }
    }
}

// MARK: - Lock Screen View

private struct OpenClawLockScreenView: View {
    let state: OpenClawActivityAttributes.ContentState
    let startTime: Date

    var body: some View {
        HStack(spacing: 12) {
            openClawStatusIndicator(for: state.status)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(startTime, style: .timer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Label("\(state.messageCount) messages", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(state.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(statusColor(for: state.status))
                }
            }
        }
        .padding()
    }
}

// MARK: - Helpers

@ViewBuilder
private func openClawStatusIndicator(
    for status: OpenClawActivityAttributes.ConversationStatus
) -> some View {
    switch status {
    case .recording:
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative.reversing)
            .foregroundStyle(.red)
    case .processing:
        Image(systemName: "ellipsis")
            .symbolEffect(.variableColor.iterative)
            .foregroundStyle(.orange)
    case .speaking:
        Image(systemName: "speaker.wave.2.fill")
            .symbolEffect(.variableColor.iterative)
            .foregroundStyle(.blue)
    case .idle:
        Image(systemName: "bolt.horizontal.icloud.fill")
            .foregroundStyle(brandAccent)
    case .ended:
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }
}

private func statusColor(
    for status: OpenClawActivityAttributes.ConversationStatus
) -> Color {
    switch status {
    case .recording: return .red
    case .processing: return .orange
    case .speaking: return .blue
    case .idle: return .secondary
    case .ended: return .green
    }
}

private func formatDuration(_ seconds: Int) -> String {
    let mins = seconds / 60
    let secs = seconds % 60
    return String(format: "%d:%02d", mins, secs)
}
