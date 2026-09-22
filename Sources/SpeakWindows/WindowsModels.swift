import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

enum WindowsModels {
    // Enabled only once the production WinHTTP runtime probe passes on Windows.
    static let streamingQualified = false
    static var live: [ModelCatalog.Option] { streamingQualified ? DesktopLiveTranscription.liveModels : [] }
    static var all: [ModelCatalog.Option] { DesktopTranscription.batchModels + live }

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
}
