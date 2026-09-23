import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CWindowsSupport

// Native WinHTTP passed all five Windows runtime probes in run 35718564307, so
// Windows keeps the shared default of DesktopHostModels.streamingQualified.
typealias WindowsModels = DesktopHostModels

extension DesktopHostModels {
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

    static func publish(status: String, refreshing: Bool) throws {
        let state = snapshot
        let order = displayOrder(state)
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
