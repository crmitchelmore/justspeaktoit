import Foundation
import SpeakCore
import SpeakDesktop

/// The process-wide model slots every desktop host presents. Slot indices are
/// stable for the life of the process, so native callbacks may carry them.
package enum DesktopHostModels {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var streamingQualified = true
        var local: [ModelCatalog.Option] = []
        var slots = DesktopModelSlots(live: DesktopLiveTranscription.liveModels)
        /// Install state shown after each local model's name.
        var localLabels: [String: String] = [:]
    }
    private static let storage = Storage()

    /// Whether this host's live WebSocket transport passed its runtime probes.
    /// Unqualified hosts offer batch models only.
    package static var streamingQualified: Bool { storage.lock.withLock { storage.streamingQualified } }

    /// Call once at startup, before anything reads the catalogue. `local` lists
    /// the on-device models this host's runtime can serve; nil keeps the
    /// current list (none by default).
    package static func configure(streamingQualified: Bool, local: [ModelCatalog.Option]? = nil) {
        storage.lock.withLock {
            storage.streamingQualified = streamingQualified
            if let local { storage.local = local }
            storage.slots = DesktopModelSlots(
                live: streamingQualified ? DesktopLiveTranscription.liveModels : [], local: storage.local
            )
        }
    }

    package static var live: [ModelCatalog.Option] { streamingQualified ? DesktopLiveTranscription.liveModels : [] }
    /// On-device models; empty on hosts without a local runtime.
    package static var local: [ModelCatalog.Option] { storage.lock.withLock { storage.local } }

    /// Stable global slot order for captured native callbacks. Use visible for pickers.
    package static var all: [ModelCatalog.Option] { snapshot.entries.map(\.option) }
    package static var visible: [ModelCatalog.Option] {
        let state = snapshot
        return state.visibleIndices.map { state.entries[$0].option }
    }
    package static var snapshot: DesktopModelSlots { storage.lock.withLock { storage.slots } }
    /// The slots and the local install labels, read together.
    package static var labelledSnapshot: (DesktopModelSlots, [String: String]) {
        storage.lock.withLock { (storage.slots, storage.localLabels) }
    }

    /// Replaces the install state shown after local model names.
    package static func setLocalLabels(_ labels: [String: String]) {
        storage.lock.withLock { storage.localLabels = labels }
    }

    package static func update(discovered: [OpenRouterAudioModel], retaining: [String]) throws {
        try storage.lock.withLock { try storage.slots.update(discovered: discovered, retaining: retaining) }
    }

    package static func provider(for model: String) -> TranscriptionProviderMetadata? {
        DesktopTranscription.provider(for: model) ?? DesktopLiveTranscription.provider(forID: model)
    }

    package static func isLive(_ model: String) -> Bool { live.contains { $0.id == model } }

    package static func isLocal(_ model: String) -> Bool { local.contains { $0.id == model } }

    // Provider metadata is untrusted UI text. Bound native control labels and
    // replace embedded controls without changing canonical model identifiers.
    package static func uiText(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(1024).map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
    }

    package static func label(for entry: DesktopModelSlots.Entry, localLabels: [String: String] = [:]) -> String {
        let name = uiText(entry.option.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = entry.isLocal ? localLabels[entry.option.id].map { " \u{2014} \($0)" } ?? ""
            : (entry.isAvailable ? "" : " (not in current catalogue)")
        return (name.isEmpty ? entry.option.id : name) + suffix
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

/// Saved model choices for the Source and Mode pickers.
package struct DesktopHostModelPreferences: Sendable {
    package let batch: String?
    package let live: String?
    package let local: String?

    package init(batch: String?, live: String?, local: String?) {
        self.batch = batch
        self.live = live
        self.local = local
    }
}
