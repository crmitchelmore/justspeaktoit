import Foundation
import SpeakDesktopHost
import CLinuxSupport

extension LinuxWindow {
    static func configureAPIKeys(_ holder: LinuxEventContext) throws {
        guard jsti_api_keys_configure(linuxAPIKeyEvent, Unmanaged.passUnretained(holder).toOpaque()) == 0 else {
            throw DesktopHostError(message: "API Keys could not be configured.")
        }
    }

    static func deliverAPIKeys(_ rows: [DesktopAPIKeyRow], request: UUID, status: String) {
        let strings = Strings()
        let native = rows.map {
            JSTILinuxAPIKeyRow(
                identifier: strings.add($0.identifier), label: strings.add($0.label), uses: strings.add($0.uses),
                status: strings.add($0.status), url: strings.add($0.keyPageURL), hint: strings.add($0.entryHint),
                saved: $0.isSaved ? 1 : 0
            )
        }
        let result = withExtendedLifetime(strings) {
            native.withUnsafeBufferPointer { rows in
                request.uuidString.withCString { request in
                    status.withCString { jsti_api_keys_finish(rows.baseAddress, rows.count, request, $0) }
                }
            }
        }
        if result != 0 { LinuxHostPlatform.update("The API Keys result could not be displayed. Reopen it to retry.") }
    }
}

private func linuxAPIKeyEvent(
    _ action: Int32, _ request: UnsafePointer<CChar>?, _ identifier: UnsafePointer<CChar>?,
    _ key: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context, let request, let ticket = UUID(uuidString: String(cString: request)) else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    if action == Int32(JSTI_LINUX_API_KEY_CANCEL) { holder.apiKeys.cancel(ticket); return }
    let name = identifier.map(String.init(cString:)) ?? ""
    let typed = key.map(String.init(cString:)) ?? ""
    holder.enqueueSettings {
        guard jsti_api_keys_request_is_current(ticket.uuidString) == 1 else { return }
        let admitted = holder.apiKeys.start(ticket) {
            guard !Task.isCancelled, jsti_api_keys_request_is_current(ticket.uuidString) == 1 else { return }
            let controller = holder.controller
            let status: String
            switch action {
            case Int32(JSTI_LINUX_API_KEY_REFRESH): status = ""
            case Int32(JSTI_LINUX_API_KEY_SAVE): status = await controller.saveAPIKey(identifier: name, key: typed)
            case Int32(JSTI_LINUX_API_KEY_REMOVE): status = await controller.removeAPIKey(identifier: name)
            case Int32(JSTI_LINUX_API_KEY_VALIDATE):
                status = await controller.validateAPIKey(identifier: name, typed: typed)
            default:
                LinuxHostPlatform.update("The API Keys request is not supported.")
                LinuxWindow.deliverAPIKeys([], request: ticket, status: "Unsupported API Keys request. Refresh to retry.")
                return
            }
            guard !Task.isCancelled else { return }
            let rows = await controller.apiKeyRows()
            guard !Task.isCancelled else { return }
            LinuxWindow.deliverAPIKeys(rows, request: ticket, status: status)
        }
        if !admitted {
            LinuxWindow.deliverAPIKeys(
                [], request: ticket, status: "An earlier key request is still finishing. Refresh again afterward."
            )
        }
    }
}
