import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CWindowsSupport

// Native WinHTTP passed all five Windows runtime probes in run 35718564307, so
// Windows configures DesktopHostModels as streaming-qualified, with its
// whisper.cpp on-device models.
typealias WindowsModels = DesktopHostModels

extension DesktopHostModels {
    /// Catalogue entries the bundled whisper.cpp runtime is qualified to serve.
    static let windowsLocal = DesktopLocalTranscription.options(host: .windows)

    /// Call first in `main`, before anything reads the catalogue.
    static func configureForWindows() {
        configure(streamingQualified: true, local: windowsLocal)
    }

    /// Remote models need their provider's key; on-device models need none.
    static func requiresKey(_ model: String) -> Bool { !isLocal(model) }

    /// Bit 0 is live, bit 1 is on-device, matching the native Source and Mode pickers.
    static func mode(of model: String) -> Int32 { (isLive(model) ? 1 : 0) + (isLocal(model) ? 2 : 0) }

    static func configureModes(batch: String?, live: String?, local: String?) throws {
        let models = all
        let modes: [Int32] = models.map { mode(of: $0.id) }
        func index(_ identifier: String?, mode: Int32) -> Int32 {
            identifier.flatMap { id in models.firstIndex { $0.id == id && self.mode(of: $0.id) == mode } }
                .map(Int32.init) ?? -1
        }
        let result = modes.withUnsafeBufferPointer {
            jsti_window_set_model_modes(
                $0.baseAddress, $0.count, index(batch, mode: 0), index(live, mode: 1), index(local, mode: 2)
            )
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not configure transcription modes.") }
    }

    static func publish(status: String, refreshing: Bool) throws {
        let (state, localLabels) = labelledSnapshot
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
                name: owned(label(for: entry, localLabels: localLabels)),
                is_live: entry.isLive ? 1 : 0, display_order: Int32(order[index] ?? -1),
                is_local: entry.isLocal ? 1 : 0
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
