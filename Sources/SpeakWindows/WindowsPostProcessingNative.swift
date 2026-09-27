import Foundation
import SpeakDesktop
import CWindowsSupport

extension WindowsNative {
    /// Remote choices from the shared cloud catalogue and the host's Local
    /// choices, each with whether it follows the prompt.
    static func configurePostProcessing(
        _ options: DesktopPostProcessing.Options, local: [(name: String, usesPrompt: Bool)] = [],
        localSelected: Int = 0, context: UnsafeMutableRawPointer
    ) throws {
        let models = DesktopPostProcessing.remoteModels
        let result = withCStrings(models.map(\.displayName)) { names in
            let selected = models.firstIndex { $0.id == options.modelIdentifier } ?? 0
            return names.withUnsafeBufferPointer { names in
                (options.customPrompt ?? "").withCString { prompt in
                    jsti_window_set_postprocessing(
                        names.baseAddress, names.count, Int32(selected), options.mode == .remote ? 1 : 0,
                        prompt, postProcessingEvent, context
                    )
                }
            }
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not configure post-processing controls.") }
        let usesPrompt = local.map { Int32($0.usesPrompt ? 1 : 0) }
        let localResult = withCStrings(local.map(\.name)) { names in
            names.withUnsafeBufferPointer { names in
                usesPrompt.withUnsafeBufferPointer { prompts in
                    jsti_window_set_local_postprocessing(
                        names.baseAddress, prompts.baseAddress, names.count,
                        Int32(local.isEmpty ? 0 : min(max(localSelected, 0), local.count - 1)),
                        options.mode == .local && !local.isEmpty ? 1 : 0
                    )
                }
            }
        }
        guard localResult == 0 else {
            throw WindowsNativeError(message: "Could not configure local post-processing controls.")
        }
    }
}
