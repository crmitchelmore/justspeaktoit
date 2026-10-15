import SpeakCore

extension DesktopVoiceOutputSettings {
    package func favoritePicker(accountInventory: VoiceAccountInventory?) -> DesktopVoicePickerPresentation {
        let picker = DesktopVoicePicker(
            voices: DesktopSpeechVoice.voices + (accountInventory?.desktopVoices ?? []),
            favoriteIDs: favoriteVoices ?? [])
        var shown = DesktopVoicePickerPresentation(
            labels: picker.voices.map { String($0.label.prefix(220)) },
            identifiers: picker.voices.map(\.favoriteIdentifier),
            favoriteRanks: picker.voices.indices.map { Int32(picker.favoriteIndices.firstIndex(of: $0) ?? -1) },
            selected: 0)
        do {
            let voice = try DesktopSpeechVoice.resolved(
                modelID: modelID, voiceID: voiceID, accountInventory: accountInventory)
            if let index = picker.voices.firstIndex(of: voice) { shown.selected = index; return shown }
        } catch {
            // Keep the stored identity unavailable rather than selecting another provider.
        }
        shown.selected = shown.labels.count
        shown.labels.append("Unavailable stored voice - choose an executable voice")
        shown.identifiers.append("")
        shown.favoriteRanks.append(-1)
        return shown
    }
}

package struct DesktopVoicePickerPresentation: Sendable {
    package var labels: [String]
    package var identifiers: [String]
    package var favoriteRanks: [Int32]
    package var selected: Int
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    /// No vault lookup or provider switch is performed by managing a favorite.
    package func handleVoicePicker(voiceID: String, action: Int32) {
        guard !closed else { return }
        let available = DesktopSpeechVoice.voices
            + voiceDiscovery.inventories.values.flatMap(\.desktopVoices)
        guard let voice = available.first(where: { $0.favoriteIdentifier == voiceID }) else {
            update("That voice is no longer available. Refresh account voices or choose an available voice.")
            return
        }
        switch action {
        case 0: selectVoiceOutput(voice)
        case 1, 2:
            var changed = voiceOutputSettings()
            changed.favoriteVoices = VoiceFavoritePreference.updating(
                changed.favoriteVoices ?? [], voiceID: voice.favoriteIdentifier, favorite: action == 1)
            _ = persistVoiceOutput(changed, message: action == 1
                ? "Added \(voice.name) to favorite voices." : "Removed \(voice.name) from favorite voices.")
        default: update("The native favorite voice action is invalid.")
        }
    }
}
