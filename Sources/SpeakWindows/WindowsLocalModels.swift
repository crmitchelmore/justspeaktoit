import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform
import CWindowsSupport

/// Saved model choices for the native Source and Mode pickers.
typealias WindowsModelPreferences = DesktopHostModelPreferences

/// The controller's Local models state: running downloads, their progress and
/// the whisper.cpp runtime once loaded. Downloads, readiness and removal are
/// the shared host's (DesktopHostLocalModelManagement.swift).
typealias WindowsLocalModelsState = DesktopHostLocalModelsState<WindowsWhisperRuntime>

typealias WindowsModelSpec = WhisperCppModel

extension WindowsWhisperRuntime: DesktopHostLocalRuntime {
    package var recognizer: any DesktopLocalRecognizer { WindowsWhisperRecognizer(runtime: self) }
}

// CNG, the bundled whisper.dll and the native Local models dialog.
extension WindowsHostPlatform {
    package static var localModelHost: LocalModelHostSupport { .windows }

    package static var localModelDigests: LocalModelDigestProvider { WindowsSHA256Hasher.provider }

    /// The runtime DLLs live beside the executable in the bundle and MSIX;
    /// developer builds point `JSTI_WHISPER_RUNTIME_DIRECTORY` at a runtime build.
    package static var localRuntimeMissing: String? {
        let library = WindowsWhisperRuntime.defaultDirectory.appendingPathComponent("whisper.dll")
        return FileManager.default.fileExists(atPath: library.path) ? nil
            : "This build does not include the on-device speech runtime. Use the Windows bundle or package."
    }

    package static func openLocalRuntime(allowGPU: Bool) throws -> WindowsWhisperRuntime {
        try WindowsWhisperRuntime.open(allowGPU: allowGPU)
    }

    package static func localRuntimeSummary(useGPU: Bool) -> String {
        let gpu = useGPU ? "a Vulkan GPU when available, otherwise the CPU" : "the CPU"
        return "On-device with whisper.cpp 1.9.4 using \(gpu). Audio stays on this PC."
    }

    package static var localModelChoiceHint: String { "Choose it under Source: Local." }

    package static func presentLocalModels(
        _ rows: [DesktopHostLocalModelRow], status: String, useGPU: Bool, presenter: UnsafeMutableRawPointer?
    ) {
        guard let presenter else { return }
        withCStrings(rows.flatMap { [$0.name, $0.detail, $0.about] } + [status]) { pointers in
            let native = rows.indices.map { index in
                JSTILocalModelRow(
                    name: pointers[index * 3], detail: pointers[index * 3 + 1], about: pointers[index * 3 + 2],
                    state: nativeState(rows[index].state)
                )
            }
            _ = native.withUnsafeBufferPointer {
                jsti_window_set_local_models(
                    $0.baseAddress, $0.count, pointers[rows.count * 3], useGPU ? 1 : 0, localModelEvent, presenter
                )
            }
        }
    }

    /// A model being removed shows as downloaded: only Remove stays enabled,
    /// and it is ignored until the removal finishes.
    private static func nativeState(_ state: DesktopHostLocalModelRow.State) -> Int32 {
        switch state {
        case .notDownloaded: return Int32(JSTI_LOCAL_MODEL_NOT_INSTALLED.rawValue)
        case .paused: return Int32(JSTI_LOCAL_MODEL_PARTIAL.rawValue)
        case .downloading: return Int32(JSTI_LOCAL_MODEL_DOWNLOADING.rawValue)
        case .downloaded, .removing: return Int32(JSTI_LOCAL_MODEL_INSTALLED.rawValue)
        }
    }
}

extension WindowsAppController {
    var localRuntimeBundled: Bool { WindowsHostPlatform.localRuntimeMissing == nil }

    func configureLocalModels(context: UnsafeMutableRawPointer) {
        configureLocalModels(presenter: context)
    }

    /// An action from the native Local models dialog.
    func localModelAction(_ action: Int32, index: Int) {
        switch action {
        case Int32(JSTI_LOCAL_MODEL_GPU_ON.rawValue), Int32(JSTI_LOCAL_MODEL_GPU_OFF.rawValue):
            setLocalUseGPU(action == Int32(JSTI_LOCAL_MODEL_GPU_ON.rawValue))
        case Int32(JSTI_LOCAL_MODEL_DOWNLOAD.rawValue): localModelAction(.download, index: index)
        case Int32(JSTI_LOCAL_MODEL_CANCEL.rawValue): localModelAction(.cancel, index: index)
        case Int32(JSTI_LOCAL_MODEL_REMOVE.rawValue): localModelAction(.remove, index: index)
        default: break
        }
    }
}

extension SpeakWindowsMain {
    /// Source and Mode pickers, then the Local models dialog.
    static func configureModelPickers(_ controller: WindowsAppController, holder: WindowsEventContext) async throws {
        let preferences = await controller.preferredModelIDs()
        try WindowsModels.configureModes(batch: preferences.batch, live: preferences.live, local: preferences.local)
        await controller.configureLocalModels(context: Unmanaged.passUnretained(holder).toOpaque())
    }
}

/// Borrowed NUL-terminated copies of `strings`, valid only inside `body`.
func withCStrings<Result>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) -> Result) -> Result {
    let owned = strings.map { string -> UnsafeMutablePointer<CChar> in
        let chars = Array(string.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
        pointer.initialize(from: chars, count: chars.count)
        return pointer
    }
    defer { owned.forEach { $0.deallocate() } }
    return body(owned.map { UnsafePointer($0) })
}

/// An action from the native Local models dialog, on the UI thread.
func localModelEvent(_ action: Int32, _ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    holder.enqueueSettings { await holder.controller.localModelAction(action, index: Int(index)) }
}
