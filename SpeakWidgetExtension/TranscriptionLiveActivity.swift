#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit
import SpeakCore

/// Live Activity widget displaying transcription status on Lock Screen and Dynamic Island.
@main
struct SpeakWidgetBundle: WidgetBundle {
    var body: some Widget {
        TranscriptionLiveActivity()
    }
}

struct TranscriptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranscriptionActivityAttributes.self) { context in
            // Lock Screen / Banner view
            LockScreenView(state: context.state, startTime: context.attributes.startTime)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded regions
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        statusIndicator(for: context.state.status)
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
                    Text(context.state.lastSnippet.isEmpty ? "Listening..." : context.state.lastSnippet)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        // Duration
                        Label(formatDuration(context.state.duration), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        // Copy action hint
                        if !context.state.lastSnippet.isEmpty {
                            Text("Tap to copy")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                statusIndicator(for: context.state.status)
            } compactTrailing: {
                Text("\(context.state.wordCount)w")
                    .font(.caption2)
            } minimal: {
                statusIndicator(for: context.state.status)
            }
        }
    }
    
    @ViewBuilder
    private func statusIndicator(for status: TranscriptionActivityAttributes.TranscriptionStatus) -> some View {
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
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Lock Screen View

struct LockScreenView: View {
    let state: TranscriptionActivityAttributes.ContentState
    let startTime: Date
    
    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            VStack {
                statusIcon
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(state.provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Text("\(state.wordCount) words • \(formatDuration(state.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let error = state.errorMessage {
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
        }
        .padding()
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch state.status {
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
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Preview

#Preview("Lock Screen", as: .content, using: TranscriptionActivityAttributes()) {
    TranscriptionLiveActivity()
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
#endif
