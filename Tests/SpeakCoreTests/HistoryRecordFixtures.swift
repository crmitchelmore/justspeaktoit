import Foundation
import SpeakCore

/// Deterministic synthetic inputs used with the unchanged legacy encoders.
enum HistoryRecordFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func richMac() -> ApplicationHistoryItem {
        ApplicationHistoryItem(
            id: identifier, createdAt: date, updatedAt: date.addingTimeInterval(15),
            modelsUsed: ["legacy/model"],
            modelUsages: [
                .init(modelIdentifier: "deepgram/nova-3", phase: .transcriptionLive),
                .init(modelIdentifier: "synthetic/polish", phase: .postProcessing)
            ],
            rawTranscription: "synthetic raw words", postProcessedTranscription: "Synthetic polished words.",
            recordingDuration: 4.25,
            cost: .init(total: Decimal(string: "0.123456789")!, currency: "USD",
                        breakdown: .init(inputTokens: 12, outputTokens: 8, totalCost: 0.01, currency: "USD")),
            audioFileURL: URL(string: "file:///synthetic-local/recording.wav"),
            networkExchanges: [.init(
                id: identifier, url: URL(string: "https://example.invalid/transcribe")!, method: "POST",
                requestHeaders: ["X-Synthetic": "fixture"], requestBodyPreview: "synthetic request",
                responseCode: 200, responseHeaders: [:], responseBodyPreview: "synthetic response"
            )],
            events: [.init(
                id: identifier, kind: .transcriptionReceived, timestamp: date, description: "Synthetic event"
            )],
            phaseTimestamps: .init(
                recordingStarted: date, recordingEnded: date.addingTimeInterval(4),
                transcriptionStarted: date, transcriptionEnded: date.addingTimeInterval(5),
                postProcessingStarted: date.addingTimeInterval(5), postProcessingEnded: date.addingTimeInterval(6),
                outputDelivered: date.addingTimeInterval(7)
            ),
            trigger: .init(gesture: .hold, hotKeyDescription: "Fn", outputMethod: .clipboard,
                           destinationApplication: "Synthetic app"),
            personalCorrections: .init(applied: [.init(
                id: identifier, ruleID: identifier, alias: "synthetic", canonical: "Synthetic", occurrences: 1,
                wasApplied: true, confidence: .high, reason: "Synthetic correction"
            )], suggestions: [], contextTags: ["fixture"], destinationApplication: "Synthetic app"),
            errors: [.init(id: identifier, phase: .output, message: "Synthetic error", occurredAt: date)],
            source: .importedFile,
            postProcessingPrompt: .init(modelIdentifier: "synthetic/polish", customPrompt: "Synthetic custom",
                                        systemPrompt: "Synthetic system", userPrompt: "Synthetic user"),
            diagnosticContext: .init(
                capturedAt: date, appVersion: "0.0.0", appBuild: "0", operatingSystem: "Synthetic OS",
                processIdentifier: 123, microphonePermission: "synthetic", inputDeviceName: "Synthetic input",
                providerLabel: "Synthetic provider", latencyTier: "fast", transcriptionMode: "live",
                transcriptionModel: "deepgram/nova-3", postProcessingModel: "synthetic/polish", speedMode: "instant"
            ),
            latency: .init(captureStartMs: 12, firstPartialMs: 234, firstInsertMs: 345, stopToFinalMs: 456),
            desktopHistory: AnyCodable(.object(["syntheticLocalState": .string("retained")]))
        )
    }

    static func minimalMac() -> ApplicationHistoryItem {
        ApplicationHistoryItem(
            id: identifier, createdAt: date, updatedAt: date,
            modelsUsed: ["legacy/model"], rawTranscription: nil, postProcessedTranscription: "",
            recordingDuration: 0, cost: nil, audioFileURL: nil, networkExchanges: [], events: [],
            phaseTimestamps: .init(), trigger: .init(gesture: .uiButton, hotKeyDescription: "", outputMethod: .none),
            personalCorrections: nil, errors: []
        )
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
