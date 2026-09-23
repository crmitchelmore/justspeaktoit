import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

enum WindowsModels {
    // Native WinHTTP passed all five Windows runtime probes in run 35718564307.
    static let streamingQualified = true
    static var live: [ModelCatalog.Option] { streamingQualified ? DesktopLiveTranscription.liveModels : [] }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var slots = DesktopModelSlots(live: WindowsModels.live)
    }
    private static let storage = Storage()
    /// Stable global slot order for captured native callbacks. Use visible for pickers.
    static var all: [ModelCatalog.Option] { snapshot.entries.map(\.option) }
    static var visible: [ModelCatalog.Option] {
        let state = snapshot
        return state.visibleIndices.map { state.entries[$0].option }
    }
    static var snapshot: DesktopModelSlots { storage.lock.withLock { storage.slots } }

    static func update(discovered: [OpenRouterAudioModel], retaining: [String]) throws {
        try storage.lock.withLock { try storage.slots.update(discovered: discovered, retaining: retaining) }
    }

    static func provider(for model: String) -> TranscriptionProviderMetadata? {
        DesktopTranscription.provider(for: model) ?? DesktopLiveTranscription.provider(forID: model)
    }

    static func isLive(_ model: String) -> Bool { live.contains { $0.id == model } }

    static func configureModes(batch: String?, live: String?) throws {
        let models = all
        let flags: [Int32] = models.map { isLive($0.id) ? 1 : 0 }
        let batchIndex = batch.flatMap { id in models.firstIndex { $0.id == id && !isLive($0.id) } } ?? -1
        let liveIndex = live.flatMap { id in models.firstIndex { $0.id == id && isLive($0.id) } } ?? -1
        let result = flags.withUnsafeBufferPointer {
            jsti_window_set_model_modes($0.baseAddress, $0.count, Int32(batchIndex), Int32(liveIndex))
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not configure transcription modes.") }
    }

    // Provider metadata is untrusted UI text. Bound native control labels and
    // replace embedded controls without changing canonical model identifiers.
    private static func uiText(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(1024).map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
    }

    private static func label(for entry: DesktopModelSlots.Entry) -> String {
        let name = uiText(entry.option.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? entry.option.id : name) + (entry.isAvailable ? "" : " (not in current catalogue)")
    }

    static func publish(status: String, refreshing: Bool) throws {
        let state = snapshot
        let order = Dictionary(uniqueKeysWithValues: state.visibleIndices.enumerated().map { ($0.element, $0.offset) })
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { $0.deallocate() } }
        func owned(_ value: String) -> UnsafePointer<CChar> {
            let chars = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
            pointer.initialize(from: chars, count: chars.count)
            strings.append(pointer)
            return UnsafePointer(pointer)
        }
        let rows = state.entries.enumerated().map { index, entry in
            JSTIModelRow(
                id: owned(entry.option.id),
                name: owned(label(for: entry)),
                is_live: entry.isLive ? 1 : 0, display_order: Int32(order[index] ?? -1)
            )
        }
        let result = rows.withUnsafeBufferPointer { rows in
            uiText(status).withCString {
                jsti_window_set_model_catalog(rows.baseAddress, rows.count, $0, refreshing ? 1 : 0)
            }
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not display the updated model catalogue.") }
    }
}

extension WindowsAppController {
    func credentialIdentifier(for model: String) throws -> String {
        guard let provider = WindowsModels.provider(for: model) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        return provider.apiKeyIdentifier
    }
}
