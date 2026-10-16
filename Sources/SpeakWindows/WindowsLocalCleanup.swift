import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform
import CWindowsSupport

extension WindowsHostPlatform {
    package static func presentPostProcessing(
        _ options: DesktopPostProcessing.Options, presenter: UnsafeMutableRawPointer?
    ) {
        guard let presenter else { return }
        do { try WindowsNative.configurePostProcessing(options, context: presenter) }
        catch { update(error.localizedDescription) }
    }
    package static func makeLocalCleanup(directory: URL) throws -> DesktopLocalLLMStore? {
        try DesktopHostLocalCleanup.makeStore(
            directory: directory, digests: WindowsSHA256Hasher.provider,
            prepareDirectory: { try preparePrivateDirectory($0) }
        )
    }

    package static func presentLocalCleanup(
        _ rows: [DesktopLocalLLMStore.Row], status: String, presenter: UnsafeMutableRawPointer?
    ) {
        guard let presenter else { return }
        withCStrings(rows.flatMap { [$0.model.id, $0.model.displayName, localCleanupDetail($0)] } + [status]) { names in
            let native = rows.enumerated().map { index, row in
                JSTILocalCleanupRow(
                    identifier: names[index * 3], name: names[index * 3 + 1], detail: names[index * 3 + 2],
                    state: localCleanupState(row)
                )
            }
            let result = native.withUnsafeBufferPointer {
                jsti_window_set_local_cleanup(
                    $0.baseAddress, $0.count, names[rows.count * 3], windowsLocalCleanupEvent, presenter
                )
            }
            if result != 0 { update("The local cleanup model controls could not be refreshed.") }
        }
    }
}

func windowsLocalCleanupEvent(
    _ action: Int32, _ identifier: UnsafePointer<CChar>?, _ repository: UnsafePointer<CChar>?,
    _ filename: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let id = identifier.map(String.init(cString:)) ?? ""
    let repo = repository.map(String.init(cString:)) ?? ""
    let file = filename.map(String.init(cString:)) ?? ""
    holder.enqueueSettings {
        await holder.controller.localCleanupAction(action, identifier: id, repository: repo, filename: file)
    }
}
