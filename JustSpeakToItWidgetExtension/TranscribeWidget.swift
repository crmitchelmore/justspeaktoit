//
//  TranscribeWidget.swift
//  JustSpeakToItWidgetExtension
//
//  Replaces the Xcode template widget ("Time:" / "Favorite Emoji:") that was
//  registered in the bundle and therefore shipped to users.
//

import AppIntents
import SwiftUI
import WidgetKit

import SpeakCore
import SpeakiOSLib

// MARK: - Timeline

struct TranscribeEntry: TimelineEntry {
    let date: Date
    /// Whether a capture is in flight, read from the App Group at refresh time.
    let isRecording: Bool
    /// When the running capture started, so the widget can render a live timer
    /// with `Text(timerInterval:)` and need no further timeline entries.
    let startedAt: Date?

    static let idlePlaceholder = TranscribeEntry(date: .now, isRecording: false, startedAt: nil)
}

struct TranscribeProvider: TimelineProvider {
    func placeholder(in context: Context) -> TranscribeEntry { .idlePlaceholder }

    func getSnapshot(in context: Context, completion: @escaping (TranscribeEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TranscribeEntry>) -> Void) {
        // One entry, never scheduled to expire: the elapsed time renders with
        // Text(timerInterval:) and state changes push a reload from the app
        // (CaptureSurfaceRefresher), so polling would only cost battery.
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> TranscribeEntry {
        let shared = SharedTranscriptionState.shared
        return TranscribeEntry(
            date: .now,
            isRecording: shared.isRecording,
            startedAt: shared.recordingStartTime
        )
    }
}

// MARK: - Views

private struct TranscribeGlyph: View {
    let isRecording: Bool

    var body: some View {
        Image(systemName: isRecording ? "waveform" : "mic.fill")
            .foregroundStyle(isRecording ? .red : .primary)
            .accessibilityHidden(true)
    }
}

/// The tappable body. On iOS 18 the button runs the toggle intent in place; on
/// iOS 17 the whole widget is a deep link that opens the app and toggles there,
/// which is what `justspeaktoit://transcribe?action=toggle` exists for.
private struct TranscribeAction<Label: View>: View {
    let label: () -> Label

    var body: some View {
        if #available(iOS 18, *) {
            Button(intent: StartTranscriptionRecordingIntent()) {
                label()
            }
            .buttonStyle(.plain)
        } else {
            label()
        }
    }
}

struct TranscribeSmallView: View {
    let entry: TranscribeEntry

    var body: some View {
        TranscribeAction {
            VStack(alignment: .leading, spacing: 6) {
                TranscribeGlyph(isRecording: entry.isRecording)
                    .font(.system(size: 26))
                Spacer(minLength: 0)
                Text(entry.isRecording ? "Recording" : "Dictate")
                    .font(.headline)
                if entry.isRecording, let startedAt = entry.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct TranscribeCircularView: View {
    let entry: TranscribeEntry

    var body: some View {
        TranscribeAction {
            ZStack {
                AccessoryWidgetBackground()
                TranscribeGlyph(isRecording: entry.isRecording)
                    .font(.title3)
            }
        }
    }
}

struct TranscribeRectangularView: View {
    let entry: TranscribeEntry

    var body: some View {
        TranscribeAction {
            HStack(spacing: 6) {
                TranscribeGlyph(isRecording: entry.isRecording)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.isRecording ? "Recording" : "Just Speak")
                        .font(.headline)
                    if entry.isRecording, let startedAt = entry.startedAt {
                        Text(startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap to dictate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct TranscribeWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TranscribeEntry

    var body: some View {
        content
            .widgetURL(URL(string: "justspeaktoit://transcribe?action=toggle"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.isRecording ? "Stop recording" : "Start recording")
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            TranscribeCircularView(entry: entry)
        case .accessoryRectangular:
            TranscribeRectangularView(entry: entry)
        case .accessoryInline:
            Label(entry.isRecording ? "Recording" : "Just Speak", systemImage: "mic.fill")
        default:
            TranscribeSmallView(entry: entry)
        }
    }
}

// MARK: - Widget

struct TranscribeWidget: Widget {
    static let kind = "TranscribeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TranscribeProvider()) { entry in
            TranscribeWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Dictate")
        .description("Start or stop a recording. The transcript goes to the destination you chose in Settings.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

#Preview(as: .systemSmall) {
    TranscribeWidget()
} timeline: {
    TranscribeEntry(date: .now, isRecording: false, startedAt: nil)
    TranscribeEntry(date: .now, isRecording: true, startedAt: .now.addingTimeInterval(-42))
}
