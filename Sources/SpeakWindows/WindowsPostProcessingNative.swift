import Foundation
import SpeakDesktop
import CWindowsSupport

extension WindowsNative {
    static func configurePostProcessing(
        _ options: DesktopPostProcessing.Options, context: UnsafeMutableRawPointer
    ) throws {
        let models = DesktopPostProcessing.remoteModels
        let pointers = models.map { model -> UnsafeMutablePointer<CChar> in
            let bytes = Array(model.displayName.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let names: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        let selected = models.firstIndex { $0.id == options.modelIdentifier } ?? 0
        let result = names.withUnsafeBufferPointer { names in
            (options.customPrompt ?? "").withCString { prompt in
                jsti_window_set_postprocessing(
                    names.baseAddress, names.count, Int32(selected), options.mode == .remote ? 1 : 0,
                    prompt, postProcessingEvent, context
                )
            }
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not configure post-processing controls.") }
    }
}
