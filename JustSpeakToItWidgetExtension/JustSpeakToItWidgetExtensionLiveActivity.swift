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
        if #available(iOS 18.0, *) {
            activityConfiguration.supplementalActivityFamilies([.small])
        } else {
            activityConfiguration
        }
    }

    private var activityConfiguration: some WidgetConfiguration {
        ActivityConfiguration(for: TranscriptionActivityAttributes.self) { context in
            if #available(iOS 18.0, *) {
                TranscriptionActivityFamilyContent(
                    state: context.state,
                    startTime: context.attributes.startTime
                )
                .widgetURL(ReleaseTrain.current.deepLink("transcribe"))
            } else {
                // Lock Screen / Banner view
                LockScreenTranscriptionView(
                    state: context.state,
                    startTime: context.attributes.startTime
                )
                .widgetURL(ReleaseTrain.current.deepLink("transcribe"))
            }
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
                    if let row = TranscriptionResultRow(state: context.state) {
                        VStack(spacing: 2) {
                            Text(row.outcomeMessage)
                                .font(.caption)
                                .foregroundStyle(.green)
                            if let preview = row.preview {
                                ResultPreviewText(
                                    preview: preview, font: .caption2, alignment: .center
                                )
                            }
                        }
                    } else {
                        Text(snippetText(for: context.state))
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

                        if context.state.status == .recording || context.state.status == .listening {
                            if #available(iOS 18, *) {
                                Button(intent: StopTranscriptionRecordingIntent()) {
                                    Label("Stop", systemImage: "stop.circle.fill")
                                        .font(.caption2)
                                }
                                .tint(.red)
                            }
                        } else if let row = TranscriptionResultRow(state: context.state) {
                            ResultRowActions(row: row)
                        }
                    }
                }
            } compactLeading: {
                transcriptionStatusIndicator(for: context.state.status)
            } compactTrailing: {
                if context.state.status == .recording || context.state.status == .listening {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                } else {
                    Text("\(context.state.wordCount)w")
                        .font(.caption2)
                }
            } minimal: {
                if context.state.status == .recording || context.state.status == .listening {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                } else {
                    transcriptionStatusIndicator(for: context.state.status)
                }
            }
            .widgetURL(ReleaseTrain.current.deepLink("transcribe"))
        }
    }
}

// MARK: - Supplemental Activity Families

/// The activity-family environment key is itself iOS 18-only, so the whole
/// stored-property owner is availability guarded rather than only its body.
@available(iOS 18.0, *)
private struct TranscriptionActivityFamilyContent: View {
    let state: TranscriptionActivityAttributes.ContentState
    let startTime: Date

    @Environment(\.activityFamily) private var activityFamily

    @ViewBuilder
    var body: some View {
        if activityFamily == .small {
            SmallTranscriptionActivityView(state: state)
        } else {
            // Medium and future families preserve the existing presentation.
            LockScreenTranscriptionView(state: state, startTime: startTime)
        }
    }
}

/// Privacy-neutral content suitable for the small Smart Stack presentation
/// and incidental small-family surfaces such as CarPlay.
@available(iOS 18.0, *)
private struct SmallTranscriptionActivityView: View {
    let state: TranscriptionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            transcriptionStatusIndicator(for: state.status)
                .font(.title3)
                .frame(width: 28)

            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if offersStop {
                Button(intent: StopTranscriptionRecordingIntent()) {
                    Text("Stop")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.red)
                .accessibilityLabel("Stop recording")
                .handGestureShortcut(.primaryAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var offersStop: Bool {
        state.status == .recording || state.status == .listening
    }

    private var statusText: String {
        switch state.status {
        case .recording: "Recording"
        case .listening: "Listening"
        case .arming: "Preparing…"
        case .armed: "Ready for speech"
        case .idle: "Ready"
        case .paused: "Paused"
        case .finalising: "Finishing…"
        case .processing: "Processing…"
        case .error: "Needs attention"
        case .completed: TranscriptionResultRow(state: state)?.outcomeMessage ?? "Finished"
        }
    }
}

// MARK: - Helpers

/// What to show when there is no snippet yet. Startup that has not proven
/// capture says so rather than claiming the microphone is live (issue #983).
private func snippetText(for state: TranscriptionActivityAttributes.ContentState) -> String {
    if !state.lastSnippet.isEmpty { return state.lastSnippet }
    return state.status == .arming ? CapturePresentationGate.preparingMessage : "Listening..."
}

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
    case .arming:
        Image(systemName: "ellipsis")
            .symbolEffect(.variableColor.iterative)
    case .armed:
        Image(systemName: "waveform.badge.mic")
            .foregroundStyle(.secondary)
    case .recording:
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative.reversing)
            .foregroundStyle(.red)
    case .finalising:
        Image(systemName: "ellipsis")
            .symbolEffect(.variableColor.iterative)
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

                    if state.status == .arming {
                        // No recording timer while capture is unproven.
                        Text(wordCountText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(wordCountText) • ")
                            .font(.caption)
                            .foregroundStyle(.secondary) +
                        Text(startTime, style: .timer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let row = TranscriptionResultRow(state: state) {
                    Text(row.outcomeMessage)
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    // The capture receipt (issue #1008), which says what each
                    // delivery lane actually did. The headline above stays the
                    // resolved outcome's own message, so this can only add
                    // detail, never upgrade the claim.
                    if !state.lastSnippet.isEmpty, state.lastSnippet != row.outcomeMessage {
                        Text(state.lastSnippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let preview = row.preview {
                        ResultPreviewText(preview: preview, font: .footnote, alignment: .leading)
                    }
                } else if let error = state.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if state.lastSnippet.isEmpty {
                    Text(snippetText(for: state))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(state.lastSnippet)
                        .font(.subheadline)
                        .lineLimit(2)
                }
            }

            if state.status == .recording || state.status == .listening {
                if #available(iOS 18, *) {
                    Button(intent: StopTranscriptionRecordingIntent()) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop recording")
                }
            } else if let resultRow {
                ResultRowActions(row: resultRow)
            }
        }
        .padding()
    }

    private var resultRow: TranscriptionResultRow? { TranscriptionResultRow(state: state) }

    /// A completed row suppresses the count when it would not be meaningful.
    private var wordCountText: String {
        if let resultRow { return resultRow.wordCountText ?? "" }
        return "\(state.wordCount) words"
    }
}

// MARK: - Result Preview

/// The completed transcript's opening line.
///
/// A Live Activity is presented on the Lock Screen and in the Dynamic Island of
/// a device that may be locked, and this is the user's private dictated text —
/// the Copy action next to it declares `.requiresAuthentication` for exactly
/// that reason, so the preview must not be the thing that leaks what Copy
/// refuses to hand over unauthenticated. When the presentation is privacy
/// redacted (a locked device), the preview is omitted entirely rather than
/// shown as redacted placeholders: the outcome headline and the word count
/// already say a recording finished and how long it was, which is all a locked
/// screen needs to convey. `privacySensitive()` marks it for any presentation
/// that redacts rather than sets the environment.
private struct ResultPreviewText: View {
    let preview: String
    let font: Font
    let alignment: TextAlignment

    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        if !redactionReasons.contains(.privacy) {
            Text(preview)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(alignment)
                .privacySensitive()
        }
    }
}

// MARK: - Result Row Actions

/// Copy runs in the app process via `LiveActivityIntent`; Open is a plain deep
/// link to the Transcribe tab. Both are shown only when the row says the
/// transcript is retrievable, so neither can imply an action that cannot happen.
private struct ResultRowActions: View {
    let row: TranscriptionResultRow

    var body: some View {
        HStack(spacing: 12) {
            if row.offersCopy, #available(iOS 18, *) {
                Button(intent: CopyLastTranscriptIntent(completionID: row.completionID)) {
                    Label(row.copyTitle, systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .tint(brandAccent)
                .accessibilityLabel(row.copyTitle)
            }

            if row.offersOpen, let url = URL(string: "justspeaktoit://transcribe") {
                Link(destination: url) {
                    Label("Open", systemImage: "arrow.up.forward.app")
                        .font(.caption2)
                }
                .accessibilityLabel("Open the transcript")
            }
        }
    }
}

// MARK: - Preview

#Preview("Small and Lock Screen states", as: .content, using: TranscriptionActivityAttributes()) {
    JustSpeakToItWidgetExtensionLiveActivity()
} contentStates: {
    TranscriptionActivityAttributes.ContentState(status: .idle, lastSnippet: "Ignored stale snippet")
    TranscriptionActivityAttributes.ContentState(status: .arming, lastSnippet: "Ignored stale snippet")
    TranscriptionActivityAttributes.ContentState(status: .armed, lastSnippet: "Ignored stale snippet")
    TranscriptionActivityAttributes.ContentState(status: .recording, lastSnippet: "Ignored live snippet")
    TranscriptionActivityAttributes.ContentState(
        status: .listening,
        lastSnippet: "Ignored live snippet",
        wordCount: 42
    )
    TranscriptionActivityAttributes.ContentState(status: .paused, lastSnippet: "Ignored stale snippet")
    TranscriptionActivityAttributes.ContentState(status: .finalising, lastSnippet: "Ignored stale snippet")
    TranscriptionActivityAttributes.ContentState(status: .processing, lastSnippet: "Ignored stale snippet")
    TranscriptionActivityAttributes.ContentState(
        status: .error,
        lastSnippet: "Ignored stale snippet",
        errorMessage: "Ignored error detail"
    )
    TranscriptionActivityAttributes.ContentState(
        status: .completed,
        lastSnippet: "Ignored stale snippet",
        completionOutcome: .ready,
        resultPreview: "Ignored result preview"
    )
}

#Preview("Completion outcomes", as: .dynamicIsland(.expanded), using: TranscriptionActivityAttributes()) {
    JustSpeakToItWidgetExtensionLiveActivity()
} contentStates: {
    TranscriptionActivityAttributes.ContentState(status: .completed, wordCount: 12, completionOutcome: .ready)
    TranscriptionActivityAttributes.ContentState(status: .completed, wordCount: 12, completionOutcome: .copied)
    TranscriptionActivityAttributes.ContentState(status: .completed, wordCount: 12, completionOutcome: .savedToHistory)
    TranscriptionActivityAttributes.ContentState(status: .completed, completionOutcome: .noSpeech)
}

#Preview("Completion outcomes", as: .content, using: TranscriptionActivityAttributes()) {
    JustSpeakToItWidgetExtensionLiveActivity()
} contentStates: {
    TranscriptionActivityAttributes.ContentState(status: .completed, wordCount: 12, completionOutcome: .ready)
    TranscriptionActivityAttributes.ContentState(status: .completed, wordCount: 12, completionOutcome: .copied)
    TranscriptionActivityAttributes.ContentState(status: .completed, wordCount: 12, completionOutcome: .savedToHistory)
    TranscriptionActivityAttributes.ContentState(status: .completed, completionOutcome: .noSpeech)
}
