import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import CWindowsSupport

extension WindowsNative {
    static func configurePostProcessing(
        _ options: DesktopPostProcessing.Options, context: UnsafeMutableRawPointer
    ) throws {
        let picker = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue().postProcessingPicker
        picker.publish([])
        let models = DesktopPostProcessing.nativeModels(selected: options.modelIdentifier)
        guard let local = models.firstIndex(where: { $0.id == LocalPostProcessingModel.builtInRulesModelID }) else {
            throw DesktopPostProcessingError.unsupportedModel
        }
        let pointers = models.map { model -> UnsafeMutablePointer<CChar> in
            let bytes = Array(model.displayName.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let names: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        let selected = models.firstIndex { $0.id == options.modelIdentifier } ?? -1
        let result = names.withUnsafeBufferPointer { names in
            (options.customPrompt ?? "").withCString { prompt in
                jsti_window_set_postprocessing(
                    names.baseAddress, names.count, Int32(selected), options.mode != .disabled ? 1 : 0,
                    Int32(local), Int32(DesktopPostProcessing.remoteSelection(for: options) ?? -1),
                    DesktopPostProcessing.localRulesNotice,
                    options.includeLexiconDirectives ? 1 : 0, options.includeContextTags ? 1 : 0,
                    prompt, postProcessingEvent, context
                )
            }
        }
        guard result == 0 else { throw WindowsNativeError(message: "Could not configure post-processing controls.") }
        guard jsti_window_set_cleanup_sources(DesktopPostProcessing.remoteModels.count) == 0 else {
            throw WindowsNativeError(message: "Could not configure local/remote cleanup sources.")
        }
        picker.publish(models)
    }
}

// The native callback's parameter list is fixed by the C ABI.
// swiftlint:disable:next function_parameter_count
func postProcessingEvent(
    _ enabled: Int32, _ index: Int32, _ includeDirectives: Int32, _ includeTags: Int32,
    _ prompt: UnsafePointer<CChar>?,
    _ newKey: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    guard let model = holder.postProcessingPicker.modelIdentifier(forSelection: Int(index)),
          enabled == 0 || enabled == 1, includeDirectives == 0 || includeDirectives == 1,
          includeTags == 0 || includeTags == 1 else {
        WindowsNative.update("Could not save post-processing settings: invalid model selection.")
        return
    }
    let prompt = prompt.map(String.init(cString:)) ?? ""
    let key = newKey.map(String.init(cString:)) ?? ""
    holder.enqueueSettings {
        await holder.controller.savePostProcessing(
            enabled: enabled != 0, modelIdentifier: model, prompt: prompt, key: key,
            includeLexiconDirectives: includeDirectives != 0, includeContextTags: includeTags != 0
        )
        let saved = await holder.controller.postProcessingOptions()
        do {
            try WindowsNative.configurePostProcessing(saved, context: Unmanaged.passUnretained(holder).toOpaque())
        } catch { WindowsNative.update(error.localizedDescription) }
    }
}
