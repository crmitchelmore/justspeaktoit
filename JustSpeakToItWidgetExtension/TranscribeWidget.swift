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

/// The kind the Xcode-template widget shipped under, before the Dictate widget
/// replaced it.
///
/// WidgetKit persists a placement by its widget *kind*. `JustSpeakToItWidget`
/// `Extension` — the unmodified template widget, the one that showed a
/// favourite emoji — shipped in every release up to v0.9.0, so a Home Screen
/// that still has one placed would, after this update, hold a widget with no
/// implementation: permanently blank, un-refreshable, and only fixable by the
/// user noticing and removing it by hand.
///
/// Registering the Dictate view under the retired kind turns those placements
/// into working Dictate widgets at the next refresh instead.
///
/// **It keeps the retired kind's original `AppIntentConfiguration`**, including
/// the template's `ConfigurationAppIntent` unchanged. WidgetKit does not
/// promise to migrate a kind between configuration types, so re-registering
/// this one as a `StaticConfiguration` — which is what the new `TranscribeWidget`
/// uses — could make the existing placements disappear rather than rescue them.
/// The configuration is therefore preserved and simply ignored: the entry view
/// reads capture state from the App Group, exactly as `TranscribeWidget` does,
/// and the emoji parameter no longer means anything.
struct LegacyTemplateTranscribeWidget: Widget {
    /// Must never change: it is the identifier already written into people's
    /// Home Screen layouts.
    static let kind = "JustSpeakToItWidgetExtension"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: LegacyTemplateConfigurationIntent.self,
            provider: LegacyTemplateProvider()
        ) { entry in
            TranscribeWidgetEntryView(entry: entry.transcribe)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Dictate")
        .description("Start or stop a recording. The transcript goes to the destination you chose in Settings.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// The template widget's configuration intent, preserved verbatim so the
/// retired kind keeps the schema it shipped with. Nothing reads `favoriteEmoji`
/// any more; it exists so the configuration type and its parameters do not
/// change underneath an existing placement.
struct LegacyTemplateConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Configuration" }
    static var description: IntentDescription { "This is an example widget." }

    @Parameter(title: "Favorite Emoji", default: "😃")
    var favoriteEmoji: String
}

struct LegacyTemplateEntry: TimelineEntry {
    let date: Date
    let configuration: LegacyTemplateConfigurationIntent
    /// The state the Dictate view actually renders from.
    let transcribe: TranscribeEntry
}

/// Feeds the retired kind from the same App Group state the Dictate widget
/// uses, through the `AppIntentTimelineProvider` its configuration requires.
struct LegacyTemplateProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LegacyTemplateEntry {
        LegacyTemplateEntry(
            date: .now,
            configuration: LegacyTemplateConfigurationIntent(),
            transcribe: .idlePlaceholder
        )
    }

    func snapshot(
        for configuration: LegacyTemplateConfigurationIntent,
        in context: Context
    ) async -> LegacyTemplateEntry {
        self.entry(for: configuration)
    }

    func timeline(
        for configuration: LegacyTemplateConfigurationIntent,
        in context: Context
    ) async -> Timeline<LegacyTemplateEntry> {
        // One entry, never scheduled to expire — the same contract as
        // `TranscribeProvider`: elapsed time renders with `Text(timerInterval:)`
        // and state changes push a reload from the app.
        Timeline(entries: [self.entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: LegacyTemplateConfigurationIntent) -> LegacyTemplateEntry {
        let shared = SharedTranscriptionState.shared
        return LegacyTemplateEntry(
            date: .now,
            configuration: configuration,
            transcribe: TranscribeEntry(
                date: .now,
                isRecording: shared.isRecording,
                startedAt: shared.recordingStartTime
            )
        )
    }
}

#Preview(as: .systemSmall) {
    TranscribeWidget()
} timeline: {
    TranscribeEntry(date: .now, isRecording: false, startedAt: nil)
    TranscribeEntry(date: .now, isRecording: true, startedAt: .now.addingTimeInterval(-42))
}
