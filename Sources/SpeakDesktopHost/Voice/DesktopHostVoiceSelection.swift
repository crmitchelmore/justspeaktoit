import SpeakCore

extension DesktopVoiceOutputSettings {
    /// Only provenance is additional state: raw intent lives in the existing IDs.
    package func storedVoice(accountInventory: VoiceAccountInventory?) throws -> DesktopSpeechVoice {
        if strictVoiceSelection == true {
            return try DesktopSpeechVoice.strictlyResolved(
                modelID: modelID, voiceID: voiceID, accountInventory: accountInventory)
        }

        return try DesktopSpeechVoice.resolved(
            modelID: modelID, voiceID: voiceID, accountInventory: accountInventory)
    }

    package func selectionProjection(over values: [String: AnyCodable]) -> [String: AnyCodable] {
        var result = values
        // Unknown strings remain exact; recognized aliases project the canonical provider identity.
        var identifier = voiceID
        if identifier == nil, strictVoiceSelection != true, modelID != nil,
           let legacy = try? storedVoice(accountInventory: nil),
           let exact = try? DesktopSpeechVoice.strictlyResolved(modelID: modelID, voiceID: legacy.transferVoiceID) {
            identifier = exact.transferVoiceID
        }
        let resolved = try? DesktopSpeechVoice.strictlyResolved(modelID: modelID, voiceID: identifier)
        result[VoiceSelectionPreference.key] = (resolved?.transferVoiceID ?? identifier)
            .map { AnyCodable(.string($0)) }
        result[VoiceSelectionPreference.modelKey] = modelID.map { AnyCodable(.string($0)) }
        return result
    }

    package mutating func applyVoiceSelection(
        _ update: VoiceSelectionPreference.Update, qualityWasProvided: Bool
    ) {
        guard update.voiceID != nil || update.modelID != nil else { return }
        if let model = update.modelID {
            let current = try? DesktopSpeechVoice.strictlyResolved(modelID: modelID, voiceID: voiceID)
            let candidate = try? DesktopSpeechVoice.strictlyResolved(
                modelID: model, voiceID: update.voiceID ?? voiceID)
            modelID = model
            if let identifier = update.voiceID { voiceID = identifier }
            if !qualityWasProvided, let candidate, candidate != current {
                alignSelectionQuality(candidate, explicitModel: true)
            }
        } else if let identifier = update.voiceID {
            let current = try? DesktopSpeechVoice.strictlyResolved(modelID: modelID, voiceID: voiceID)
            let candidate = try? DesktopSpeechVoice.strictlyResolved(modelID: nil, voiceID: identifier)
            // A scalar reimport cannot erase a model that it cannot represent.
            let unchanged = identifier == voiceID
                || (current != nil && current?.transferVoiceID == candidate?.transferVoiceID)
            if !unchanged, let candidate {
                modelID = candidate.modelID
                voiceID = candidate.id
                if !qualityWasProvided { alignSelectionQuality(candidate) }
            } else if !unchanged {
                // Retaining unsupported intent is not successful resolution or permission to execute.
                modelID = nil
                voiceID = identifier
            }
        }
        strictVoiceSelection = true
    }

    private mutating func alignSelectionQuality(_ voice: DesktopSpeechVoice, explicitModel: Bool = false) {
        if case .openai = voice { quality = explicitModel ? nil : voice.defaultQuality.rawValue }
        if case .elevenlabs = voice { quality = explicitModel ? nil : voice.defaultQuality.rawValue }
    }
}

extension DesktopHostController {
    nonisolated static func importStoredVoiceSelection(into settings: inout Settings) throws {
        let keys = VoiceSelectionPreference.keys.intersection(Platform.voiceConfigurationKeys)
        guard let configuration = settings.configuration,
              !keys.isDisjoint(with: configuration.values.keys) else { return }
        let claimed = keys.union(
            [VoiceSynthesisPreference.quality.key.rawValue].filter { Platform.voiceConfigurationKeys.contains($0) })
        var voice = settings.voiceOutput
        let selection = try DesktopConfiguration(values: configuration.values.filter { claimed.contains($0.key) })
        _ = try Platform.importVoiceConfiguration(from: selection, into: &voice)
        let remaining = try DesktopConfiguration(values: configuration.values.filter { !claimed.contains($0.key) })
        settings.voiceOutput = voice
        settings.configuration = remaining
    }
}
