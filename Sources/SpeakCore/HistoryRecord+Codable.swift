import Foundation

extension HistoryRecord {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.schemaVersion) {
            let version = try values.decode(Int.self, forKey: .schemaVersion)
            guard version == Self.currentSchemaVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion, in: values,
                    debugDescription: "Unsupported local history schema version: \(version)"
                )
            }
        } else {
            let legacy = try decoder.container(keyedBy: IOSLegacyKeys.self)
            if legacy.contains(.transcription) {
                self = try Self.decodeIOSLegacy(legacy)
                return
            }
        }
        self = try Self.decodeLocal(values)
    }

    private static func decodeLocal(_ values: KeyedDecodingContainer<CodingKeys>) throws -> Self {
        Self(
            id: try values.decode(UUID.self, forKey: .id),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt),
            modelsUsed: try values.decodeIfPresent([String].self, forKey: .modelsUsed) ?? [],
            modelUsages: try values.decodeIfPresent([ApplicationModelUsage].self, forKey: .modelUsages) ?? [],
            rawTranscription: try values.decodeIfPresent(String.self, forKey: .rawTranscription),
            postProcessedTranscription: try values.decodeIfPresent(String.self, forKey: .postProcessedTranscription),
            recordingDuration: try values.decode(TimeInterval.self, forKey: .recordingDuration),
            cost: try values.decodeIfPresent(ApplicationHistoryCost.self, forKey: .cost),
            audioFileURL: try values.decodeIfPresent(URL.self, forKey: .audioFileURL),
            networkExchanges: try values.decodeIfPresent(
                [ApplicationHistoryNetworkExchange].self, forKey: .networkExchanges
            ) ?? [],
            events: try values.decodeIfPresent([ApplicationHistoryEvent].self, forKey: .events) ?? [],
            phaseTimestamps: try values.decodeIfPresent(ApplicationPhaseTimestamps.self, forKey: .phaseTimestamps),
            trigger: try values.decodeIfPresent(ApplicationHistoryTrigger.self, forKey: .trigger),
            personalCorrections: try values.decodeIfPresent(
                PersonalLexiconHistorySummary.self, forKey: .personalCorrections
            ),
            errors: try values.decodeIfPresent([ApplicationHistoryError].self, forKey: .errors) ?? [],
            source: try values.decodeIfPresent(ApplicationHistoryItemSource.self, forKey: .source),
            postProcessingPrompt: try values.decodeIfPresent(
                ApplicationPostProcessingPromptPayload.self, forKey: .postProcessingPrompt
            ),
            diagnosticContext: try values.decodeIfPresent(
                ApplicationHistoryDiagnosticContext.self, forKey: .diagnosticContext
            ),
            latency: try values.decodeIfPresent(SessionLatencyMetrics.self, forKey: .latency),
            desktopHistory: try values.decodeIfPresent(AnyCodable.self, forKey: .desktopHistory),
            model: try values.decodeIfPresent(String.self, forKey: .model),
            wordCount: try values.decodeIfPresent(Int.self, forKey: .wordCount),
            originPlatform: try values.decodeIfPresent(String.self, forKey: .originPlatform) ?? "macos",
            errorMessage: try values.decodeIfPresent(String.self, forKey: .errorMessage),
            requestContext: try? values.decodeIfPresent(RequestDiagnosticContext.self, forKey: .requestContext)
        )
    }

    private enum IOSLegacyKeys: String, CodingKey {
        case id, createdAt, updatedAt, transcription, postProcessedTranscription
        case model, duration, wordCount, originPlatform, errorMessage, requestContext
    }

    private static func decodeIOSLegacy(_ values: KeyedDecodingContainer<IOSLegacyKeys>) throws -> Self {
        let createdAt = try values.decode(Date.self, forKey: .createdAt)
        return Self(
            id: try values.decode(UUID.self, forKey: .id),
            createdAt: createdAt,
            updatedAt: try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt,
            rawTranscription: try values.decode(String.self, forKey: .transcription),
            postProcessedTranscription: try values.decodeIfPresent(String.self, forKey: .postProcessedTranscription),
            recordingDuration: try values.decode(TimeInterval.self, forKey: .duration),
            model: try values.decode(String.self, forKey: .model),
            wordCount: try values.decode(Int.self, forKey: .wordCount),
            originPlatform: try values.decodeIfPresent(String.self, forKey: .originPlatform) ?? "ios",
            errorMessage: try values.decodeIfPresent(String.self, forKey: .errorMessage),
            requestContext: try? values.decodeIfPresent(RequestDiagnosticContext.self, forKey: .requestContext)
        )
    }
}
