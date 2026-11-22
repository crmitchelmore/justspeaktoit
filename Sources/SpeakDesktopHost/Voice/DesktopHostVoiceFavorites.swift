import SpeakCore

extension DesktopVoiceOutputSettings {
    package func favoritePicker(
        accountInventory: VoiceAccountInventory?,
        voiceProfiles: [VoiceProfile] = []
    ) -> DesktopVoicePickerPresentation {
        let myEntries = VoiceProfilePickerCatalog.entries(from: voiceProfiles)
        let picker = DesktopVoicePicker(
            voices: DesktopSpeechVoice.voices + (accountInventory?.desktopVoices ?? []),
            favoriteIDs: favoriteVoices ?? [])
        let labels = myEntries.map { String($0.desktopPickerLabel.prefix(220)) }
            + picker.voices.map { String($0.label.prefix(220)) }
        let identifiers = myEntries.map(\.desktopPickerIdentifier)
            + picker.voices.map(\.pickerIdentifier)
        let favoriteTargets = myEntries.map(\.id) + picker.voices.map(\.favoriteIdentifier)
        let savedFavorites = favoriteVoices ?? []
        var uniqueFavorites: [String] = []
        for identifier in savedFavorites where !uniqueFavorites.contains(identifier) {
            uniqueFavorites.append(identifier)
        }
        let favoriteRows = uniqueFavorites.flatMap { favID in
            favoriteTargets.indices.filter { favoriteTargets[$0] == favID }
        }
        var favoriteRanks = [Int32](repeating: -1, count: labels.count)
        for (rank, index) in favoriteRows.enumerated() { favoriteRanks[index] = Int32(rank) }

        var shown = DesktopVoicePickerPresentation(
            labels: labels,
            identifiers: identifiers,
            favoriteRanks: favoriteRanks,
            selected: 0)

        if let voiceID,
           let profileIndex = myEntries.firstIndex(where: {
               ($0.id == voiceID && (modelID == nil || modelID == $0.engineID))
                   || $0.desktopPickerIdentifier == voiceID
           }) {
            shown.selected = profileIndex
            return shown
        }

        do {
            let voice = try resolvedVoice(accountInventory: accountInventory)
            if let index = picker.voices.firstIndex(of: voice) {
                shown.selected = myEntries.count + index
                return shown
            }
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
        if let profileEntry = VoiceProfilePickerCatalog.resolve(
            desktopPickerIdentifier: voiceID,
            in: listVoiceProfiles()
        ) {
            handleMyVoicePickerAction(profileEntry, action: action)
            return
        }
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

    private func handleMyVoicePickerAction(_ entry: MyVoicePickerEntry, action: Int32) {
        switch action {
        case 0:
            if let executable = try? DesktopSpeechVoice.strictlyResolved(
                modelID: entry.engineID,
                voiceID: entry.id,
                accountInventory: selectedVoiceAccountInventory
            ) {
                selectVoiceOutput(executable)
                return
            }
            var changed = voiceOutputSettings()
            changed.modelID = entry.engineID
            changed.voiceID = entry.id
            changed.strictVoiceSelection = true
            _ = persistVoiceOutput(changed, message: "Selected \(entry.displayName).")
        case 1, 2:
            var changed = voiceOutputSettings()
            changed.favoriteVoices = VoiceFavoritePreference.updating(
                changed.favoriteVoices ?? [], voiceID: entry.id, favorite: action == 1)
            _ = persistVoiceOutput(changed, message: action == 1
                ? "Added \(entry.displayName) to favorite voices."
                : "Removed \(entry.displayName) from favorite voices.")
        default:
            update("The native favorite voice action is invalid.")
        }
    }
}
