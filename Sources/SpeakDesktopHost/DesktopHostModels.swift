import Foundation
import SpeakCore
import SpeakDesktop

/// The process-wide model slots every desktop host presents. Slot indices are
/// stable for the life of the process, so native callbacks may carry them.
package enum DesktopHostModels {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var streamingQualified = true
        var slots = DesktopModelSlots(live: DesktopLiveTranscription.liveModels)
    }
    private static let storage = Storage()

    /// Whether this host's live WebSocket transport passed its runtime probes.
    /// Unqualified hosts offer batch models only.
    package static var streamingQualified: Bool { storage.lock.withLock { storage.streamingQualified } }

    /// Call once at startup, before anything reads the catalogue.
    package static func configure(streamingQualified: Bool) {
        storage.lock.withLock {
            storage.streamingQualified = streamingQualified
            storage.slots = DesktopModelSlots(live: streamingQualified ? DesktopLiveTranscription.liveModels : [])
        }
    }

    package static var live: [ModelCatalog.Option] { streamingQualified ? DesktopLiveTranscription.liveModels : [] }

    /// Stable global slot order for captured native callbacks. Use visible for pickers.
    package static var all: [ModelCatalog.Option] { snapshot.entries.map(\.option) }
    package static var visible: [ModelCatalog.Option] {
        let state = snapshot
        return state.visibleIndices.map { state.entries[$0].option }
    }
    package static var snapshot: DesktopModelSlots { storage.lock.withLock { storage.slots } }

    package static func update(discovered: [OpenRouterAudioModel], retaining: [String]) throws {
        try storage.lock.withLock { try storage.slots.update(discovered: discovered, retaining: retaining) }
    }

    package static func provider(for model: String) -> TranscriptionProviderMetadata? {
        DesktopTranscription.provider(for: model) ?? DesktopLiveTranscription.provider(forID: model)
    }

    package static func isLive(_ model: String) -> Bool { live.contains { $0.id == model } }

    // Provider metadata is untrusted UI text. Bound native control labels and
    // replace embedded controls without changing canonical model identifiers.
    package static func uiText(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(1024).map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
    }

    package static func label(for entry: DesktopModelSlots.Entry) -> String {
        let name = uiText(entry.option.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? entry.option.id : name) + (entry.isAvailable ? "" : " (not in current catalogue)")
    }

    /// Picker position of each visible global slot.
    package static func displayOrder(_ state: DesktopModelSlots) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: state.visibleIndices.enumerated().map { ($0.element, $0.offset) })
    }
}

/// Imported audio accepted by every desktop host.
package enum DesktopHostImport {
    package static func validate(_ source: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DesktopHostError(message: "Choose a regular audio file to import.")
        }
        guard let size = values.fileSize, size > 0, size <= 25_000_000 else {
            throw DesktopHostError(message: "Choose a non-empty audio file no larger than 25 MB.")
        }
        guard ["wav", "mp3", "mp4", "m4a", "aac", "flac", "ogg", "opus", "webm"]
            .contains(source.pathExtension.lowercased()) else {
            throw DesktopHostError(message: "Choose a WAV, MP3, MP4, M4A, AAC, FLAC, OGG, Opus or WebM audio file.")
        }
    }
}
