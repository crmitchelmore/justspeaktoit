#if DEBUG
import Foundation
import SpeakCore

/// Website screenshots and the demo video come from the real Debug app inside the
/// isolated core journey profile. This opt-in seeds fictional History only; the
/// transcript returned by the batch fixture is fixed text, not speech recognition.
enum CoreJourneySiteMediaFixture {
    nonisolated static let environmentKey = "SPEAK_CORE_JOURNEY_SITE_MEDIA"
    nonisolated static let transcript = "Remind me to send the revised launch notes to the team before Friday."

    nonisolated static let appearanceKey = "SPEAK_CORE_JOURNEY_SITE_MEDIA_APPEARANCE"

    /// Light or dark capture for the website's matching video variants; nil keeps the default.
    nonisolated static var requestedAppearance: AppSettings.Appearance? {
        ProcessInfo.processInfo.environment[appearanceKey].flatMap(AppSettings.Appearance.init(rawValue:))
    }

    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static func seedHistory(in directory: URL, now: Date = Date()) throws {
        let historyDirectory = directory
            .appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sampleItems(now: now))
        try data.write(to: historyDirectory.appendingPathComponent("history-log.json"), options: .atomic)
    }

    /// Fictional personal corrections so the Corrections page has something to show.
    static func seedCorrections(in directory: URL, now: Date = Date()) throws {
        let lexiconDirectory = directory
            .appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
            .appendingPathComponent("PersonalLexicon", isDirectory: true)
        try FileManager.default.createDirectory(at: lexiconDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sampleCorrections(now: now))
        try data.write(to: lexiconDirectory.appendingPathComponent("lexicon.json"), options: .atomic)
    }

    static func sampleCorrections(now: Date) -> [PersonalLexiconRule] {
        [
            ("Project name", "Lighthouse", ["light house", "lighthouse"], ["work"]),
            ("Colleague", "Saoirse", ["seer sha", "sir sha"], ["people"]),
            ("Product", "Kestrel API", ["kestral api", "castrel a p i"], ["work"])
        ].map { name, canonical, aliases, tags in
            PersonalLexiconRule(
                displayName: name, canonical: canonical, aliases: aliases, activation: .automatic,
                contextTags: Set(tags), confidence: .high, notes: nil, source: .manual,
                createdAt: now.addingTimeInterval(-86_400), updatedAt: now.addingTimeInterval(-86_400)
            )
        }
    }

    static func sampleItems(now: Date) -> [HistoryItem] {
        [
            item(
                minutesAgo: 18, duration: 41, gesture: .hold, output: .accessibility, app: "Mail",
                transcription: ("deepgram/nova-3-streaming", .transcriptionLive),
                polish: "openai/gpt-5-mini",
                raw: "hi sam thanks for the notes from yesterday i've gone through the draft and the only "
                    + "thing i'd change is the timeline on the second page can we move the review to thursday",
                processed: "Hi Sam, thanks for the notes from yesterday. I've gone through the draft, and the only "
                    + "thing I'd change is the timeline on the second page. Can we move the review to Thursday?",
                cost: 0.004, now: now
            ),
            item(
                minutesAgo: 64, duration: 12, gesture: .doubleTap, output: .accessibility, app: "Xcode",
                transcription: ("local/whisperkit/large-v3-turbo", .transcriptionLocal), polish: nil,
                raw: "Add a guard for the empty state before we render the list.", processed: nil,
                cost: nil, now: now
            ),
            item(
                minutesAgo: 190, duration: 27, gesture: .hold, output: .accessibility, app: "Notes",
                transcription: ("elevenlabs/scribe_v2", .transcriptionBatch),
                polish: "local/post-processing/rules",
                raw: "shopping list um oat milk two lemons coffee beans and the good bread from the market",
                processed: "Shopping list: oat milk, two lemons, coffee beans and the good bread from the market.",
                cost: 0.002, now: now
            ),
            item(
                minutesAgo: 1_470, duration: 19, gesture: .doubleTap, output: .clipboard, app: "Slack",
                transcription: ("deepgram/nova-3-streaming", .transcriptionLive), polish: nil,
                raw: "Running five minutes late, start without me and I'll catch up on the action items.",
                processed: nil, cost: 0.001, now: now
            ),
            item(
                minutesAgo: 2_910, duration: 58, gesture: .hold, output: .accessibility, app: "Pages",
                transcription: ("local/whisperkit/large-v3-turbo", .transcriptionLocal),
                polish: "openai/gpt-5-mini",
                raw: "the second chapter opens on the harbour just after dawn when the fishing boats are "
                    + "coming back in and nobody has noticed the lighthouse is dark",
                processed: "The second chapter opens on the harbour just after dawn, when the fishing boats are "
                    + "coming back in and nobody has noticed that the lighthouse is dark.",
                cost: 0.003, now: now
            )
        ]
    }

    // swiftlint:disable:next function_parameter_count
    private static func item(
        minutesAgo: Double, duration: TimeInterval, gesture: HistoryTrigger.HotKeyGesture,
        output: HistoryTrigger.OutputMethod, app: String,
        transcription: (model: String, phase: ModelUsagePhase), polish: String?,
        raw: String, processed: String?, cost: Double?, now: Date
    ) -> HistoryItem {
        let started = now.addingTimeInterval(-minutesAgo * 60)
        let ended = started.addingTimeInterval(duration)
        let transcribed = ended.addingTimeInterval(0.6)
        let polished = polish == nil ? nil : transcribed.addingTimeInterval(0.9)
        let delivered = (polished ?? transcribed).addingTimeInterval(0.1)
        var usages = [ModelUsage(modelIdentifier: transcription.model, phase: transcription.phase)]
        var events: [HistoryEvent] = [
            .init(kind: .recordingStarted, timestamp: started, description: "Recording began"),
            .init(kind: .recordingStopped, timestamp: ended, description: "Recording finished"),
            .init(kind: .transcriptionReceived, timestamp: transcribed, description: "Transcription succeeded")
        ]
        if let polish, let polished {
            usages.append(ModelUsage(modelIdentifier: polish, phase: .postProcessing))
            events.append(.init(
                kind: .postProcessingReceived, timestamp: polished, description: "Post-processing succeeded"
            ))
        }
        events.append(.init(kind: .outputDelivered, timestamp: delivered, description: "Output delivered"))
        return HistoryItem(
            createdAt: started, updatedAt: delivered,
            modelsUsed: usages.map(\.modelIdentifier), modelUsages: usages,
            rawTranscription: raw, postProcessedTranscription: processed, recordingDuration: duration,
            cost: cost.map { HistoryCost(total: Decimal($0), currency: "USD", breakdown: nil) },
            audioFileURL: nil, networkExchanges: [], events: events,
            phaseTimestamps: .init(
                recordingStarted: started, recordingEnded: ended,
                transcriptionStarted: ended, transcriptionEnded: transcribed,
                postProcessingStarted: polish == nil ? nil : transcribed, postProcessingEnded: polished,
                outputDelivered: delivered
            ),
            trigger: .init(
                gesture: gesture, hotKeyDescription: "Fn", outputMethod: output, destinationApplication: app
            ),
            personalCorrections: nil, errors: []
        )
    }
}
#endif
