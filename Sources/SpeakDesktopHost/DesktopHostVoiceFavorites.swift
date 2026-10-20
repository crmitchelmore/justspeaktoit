import SpeakCore

extension DesktopVoiceOutputSettings {
    package func favoritePicker(accountInventory: VoiceAccountInventory?) -> DesktopVoicePickerPresentation {
        let picker = DesktopVoicePicker(
            voices: DesktopSpeechVoice.voices + (accountInventory?.desktopVoices ?? []),
            favoriteIDs: favoriteVoices ?? [])
        let favoriteRows = picker.favoriteIndices.flatMap { favorite in
            picker.voices.indices.filter {
                picker.voices[$0].favoriteIdentifier == picker.voices[favorite].favoriteIdentifier
            }
        }
        var favoriteRanks = [Int32](repeating: -1, count: picker.voices.count)
        for (rank, index) in favoriteRows.enumerated() { favoriteRanks[index] = Int32(rank) }
        var shown = DesktopVoicePickerPresentation(
            labels: picker.voices.map { String($0.label.prefix(220)) },
            identifiers: picker.voices.map(\.pickerIdentifier),
            favoriteRanks: favoriteRanks,
            selected: 0)
        do {
            let voice = try resolvedVoice(accountInventory: accountInventory)
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
    package func selectQuickVoice(_ slot: Int) {
        guard !closed else { return }
        guard (1...3).contains(slot) else {
            update("Quick Voice needs a slot from 1 to 3.")
            return
        }
        let saved = voiceOutputSettings()
        let favorites = saved.favoriteVoices ?? []
        guard favorites.indices.contains(slot - 1) else {
            update("Quick Voice \(slot) has no saved favorite. Add favorites in Voice Output.")
            return
        }
        let identifier = favorites[slot - 1]
        let available = DesktopSpeechVoice.voices + voiceDiscovery.inventories.values.flatMap(\.desktopVoices)
        let matching = available.filter { $0.favoriteIdentifier == identifier }
        guard let voice = matching.first(where: { $0.modelID == saved.modelID }) ?? matching.first else {
            update("Quick Voice \(slot) is unavailable. Refresh account voices or update Favorites in Voice Output.")
            return
        }
        selectVoiceOutput(voice)
    }

    /// No vault lookup or provider switch is performed by managing a favorite.
    package func handleVoicePicker(voiceID: String, action: Int32) {
        guard !closed else { return }
        let available = DesktopSpeechVoice.voices
            + voiceDiscovery.inventories.values.flatMap(\.desktopVoices)
        guard let voice = available.first(where: { $0.pickerIdentifier == voiceID }) else {
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
