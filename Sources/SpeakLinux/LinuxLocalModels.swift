import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

extension LinuxWhisperRuntime: DesktopHostLocalRuntime {
    package var recognizer: any DesktopLocalRecognizer { LinuxWhisperRecognizer(runtime: self) }
}

// On-device transcription: the shared host owns downloads, readiness, removal
// and recognition (DesktopHostLocalModelManagement.swift); Linux supplies
// GChecksum, the whisper.cpp runtime beside the executable and the GTK group.
extension LinuxHostPlatform: DesktopHostLocalModelPlatform {
    typealias LocalRuntime = LinuxWhisperRuntime
    typealias LocalModelsState = DesktopHostLocalModelsState<LinuxWhisperRuntime>

    package static var localModelHost: LocalModelHostSupport { .linux }

    package static var localModelDigests: LocalModelDigestProvider { LinuxSHA256Hasher.provider }

    package static var localRuntimeMissing: String? {
        let library = LinuxWhisperRuntime.defaultDirectory.appendingPathComponent(LinuxWhisperRuntime.libraryName)
        return FileManager.default.fileExists(atPath: library.path) ? nil
            : "This build does not include the on-device speech runtime. Install it beside the app "
                + "or set JSTI_WHISPER_RUNTIME_DIRECTORY (see Docs/linux-development.md)."
    }

    package static func openLocalRuntime(allowGPU: Bool) throws -> LinuxWhisperRuntime {
        try LinuxWhisperRuntime.open(allowGPU: allowGPU)
    }

    /// Only a runtime built with the optional Vulkan backend can use a GPU.
    static var runtimeHasGPUBackend: Bool {
        let backend = LinuxWhisperRuntime.defaultDirectory.appendingPathComponent(LinuxWhisperRuntime.vulkanBackendName)
        return FileManager.default.fileExists(atPath: backend.path)
    }

    package static func localRuntimeSummary(useGPU: Bool) -> String {
        let processor = runtimeHasGPUBackend && useGPU ? "a Vulkan GPU when available, otherwise the CPU" : "the CPU"
        return "On-device with whisper.cpp 1.9.4 using \(processor). Audio stays on \(localDeviceName)."
    }

    package static var localModelChoiceHint: String { "Choose it as the transcription model." }

    package static func presentLocalModels(
        _ rows: [DesktopHostLocalModelRow], status: String, useGPU: Bool, presenter: UnsafeMutableRawPointer?
    ) {
        let strings = LinuxWindow.Strings()
        let native = rows.map { row in
            JSTILocalModelRow(
                name: strings.add(row.name), detail: strings.add(row.detail), about: strings.add(row.about),
                state: nativeState(row.state)
            )
        }
        let gpu: Int32 = runtimeHasGPUBackend ? (useGPU ? 1 : 0) : -1
        let result = withExtendedLifetime(strings) {
            native.withUnsafeBufferPointer {
                jsti_window_set_local_models($0.baseAddress, $0.count, DesktopHostModels.uiText(status), gpu)
            }
        }
        if result != 0 { update("Local models could not be refreshed.") }
    }

    private static func nativeState(_ state: DesktopHostLocalModelRow.State) -> Int32 {
        switch state {
        case .notDownloaded: return Int32(JSTI_LOCAL_MODEL_NOT_INSTALLED)
        case .paused: return Int32(JSTI_LOCAL_MODEL_PARTIAL)
        case .downloading: return Int32(JSTI_LOCAL_MODEL_DOWNLOADING)
        case .downloaded: return Int32(JSTI_LOCAL_MODEL_INSTALLED)
        case .removing: return Int32(JSTI_LOCAL_MODEL_REMOVING)
        }
    }
}

/// Local models events, applied in settings order. Returns false for others.
func linuxLocalModelEvent(_ event: Int, slot: Int, holder: LinuxEventContext) -> Bool {
    let controller = holder.controller
    let action: DesktopHostLocalModelAction
    switch event {
    case Int(JSTI_EVENT_LOCAL_MODEL_DOWNLOAD): action = .download
    case Int(JSTI_EVENT_LOCAL_MODEL_CANCEL): action = .cancel
    case Int(JSTI_EVENT_LOCAL_MODEL_REMOVE): action = .remove
    case Int(JSTI_EVENT_LOCAL_MODEL_GPU):
        holder.enqueueSettings { await controller.setLocalUseGPU(slot == 1) }
        return true
    default: return false
    }
    // In click order, so a Cancel right after Download finds the download.
    holder.enqueueSettings { await controller.localModelAction(action, index: slot) }
    return true
}
