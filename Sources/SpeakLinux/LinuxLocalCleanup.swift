import Foundation
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

extension LinuxHostPlatform {
    package static func presentPostProcessing(
        _ options: DesktopPostProcessing.Options, presenter: UnsafeMutableRawPointer?
    ) {
        LinuxWindow.postProcessing(options)
    }
    package static func makeLocalCleanup(directory: URL) throws -> DesktopLocalLLMStore? {
        try DesktopHostLocalCleanup.makeStore(
            directory: directory, digests: LinuxSHA256Hasher.provider,
            prepareDirectory: { try preparePrivateDirectory($0) }
        )
    }

    package static func presentLocalCleanup(
        _ rows: [DesktopLocalLLMStore.Row], status: String, presenter: UnsafeMutableRawPointer?
    ) {
        guard let presenter else { return }
        let strings = LinuxWindow.Strings()
        let native = rows.map {
            JSTILocalCleanupRow(
                identifier: strings.add($0.model.id), name: strings.add($0.model.displayName),
                detail: strings.add(localCleanupDetail($0)), state: localCleanupState($0)
            )
        }
        let result = withExtendedLifetime(strings) {
            native.withUnsafeBufferPointer {
                jsti_window_set_local_cleanup($0.baseAddress, $0.count, status, linuxLocalCleanupEvent, presenter)
            }
        }
        if result != 0 { update("The local cleanup model controls could not be refreshed.") }
    }
}

func linuxLocalCleanupEvent(
    _ action: Int32, _ identifier: UnsafePointer<CChar>?, _ repository: UnsafePointer<CChar>?,
    _ filename: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    let id = identifier.map(String.init(cString:)) ?? ""
    let repo = repository.map(String.init(cString:)) ?? ""
    let file = filename.map(String.init(cString:)) ?? ""
    holder.enqueueSettings {
        await holder.controller.localCleanupAction(action, identifier: id, repository: repo, filename: file)
    }
}
