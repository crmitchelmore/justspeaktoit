import Foundation
import SpeakDesktop
import SpeakDesktopHost
import CLinuxSupport

extension LinuxWindow {
    static func configureAPIKeys(_ holder: LinuxEventContext) throws {
        guard jsti_api_keys_configure(linuxAPIKeyEvent, holder.callbackContext) == 0 else {
            throw DesktopHostError(message: "API Keys could not be configured.")
        }
    }

    static func deliverAPIKeys(_ rows: [DesktopAPIKeyRow], request: UUID, status: String) {
        let strings = DesktopNativeStrings()
        let native = rows.map {
            JSTILinuxAPIKeyRow(
                identifier: strings.add($0.identifier), label: strings.add($0.label), uses: strings.add($0.uses),
                status: strings.add($0.status), url: strings.add($0.keyPageURL), hint: strings.add($0.entryHint),
                saved: $0.isSaved ? 1 : 0, filters: $0.filterMask
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

    /// Balance text beside one key, on its own channel so it never makes the
    /// dialog pending. The text comes from the shared formatter, never a key.
    static func presentAPIKeyBalance(_ line: DesktopProviderBalanceLine) {
        let result = line.identifier.withCString { identifier in
            line.text.withCString { text in
                jsti_api_keys_set_balance(identifier, text, line.canRefresh ? 1 : 0, line.isResult ? 1 : 0)
            }
        }
        if result != 0 { LinuxHostPlatform.update("A provider balance could not be shown. Reopen API Keys to retry.") }
    }
}

private func linuxAPIKeyEvent(
    _ action: Int32, _ request: UnsafePointer<CChar>?, _ identifier: UnsafePointer<CChar>?,
    _ key: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context, let request, let ticket = UUID(uuidString: String(cString: request)) else { return }
    guard let holder = NativeCallbackContext<LinuxEventContext>.resolve(context) else { return }
    if action == Int32(JSTI_LINUX_API_KEY_CANCEL) { holder.apiKeys.cancel(ticket); return }
    let name = identifier.map(String.init(cString:)) ?? ""
    if action == Int32(JSTI_LINUX_API_KEY_BALANCE) {
        // Outside the request ticket: a balance check never holds key entry.
        holder.enqueueSettings { await holder.balances.refresh(credentialIdentifier: name) }
        return
    }
    let typed = key.map(String.init(cString:)) ?? ""
    holder.enqueueSettings {
        guard jsti_api_keys_request_is_current(ticket.uuidString) == 1 else { return }
        let admitted = holder.apiKeys.start(ticket) {
            await linuxRunAPIKeyAction(action, ticket: ticket, name: name, typed: typed, holder: holder)
        }
        if !admitted {
            LinuxWindow.deliverAPIKeys(
                [], request: ticket, status: "An earlier key request is still finishing. Refresh again afterward."
            )
        }
    }
}

/// One admitted API Keys action: runs it, delivers the rows, then updates their balance lines.
private func linuxRunAPIKeyAction(
    _ action: Int32, ticket: UUID, name: String, typed: String, holder: LinuxEventContext
) async {
    guard !Task.isCancelled, jsti_api_keys_request_is_current(ticket.uuidString) == 1 else { return }
    let controller = holder.controller
    guard let status = await linuxAPIKeyStatus(action, name: name, typed: typed, controller: controller) else {
        LinuxHostPlatform.update("The API Keys request is not supported.")
        LinuxWindow.deliverAPIKeys([], request: ticket, status: "Unsupported API Keys request. Refresh to retry.")
        return
    }
    if action == Int32(JSTI_LINUX_API_KEY_SAVE) || action == Int32(JSTI_LINUX_API_KEY_REMOVE) {
        await holder.balances.credentialChanged(name)
    }
    guard !Task.isCancelled else { return }
    let rows = await controller.apiKeyRows()
    guard !Task.isCancelled else { return }
    LinuxWindow.deliverAPIKeys(rows, request: ticket, status: status)
    await linuxRefreshBalances(after: action, name: name, rows: rows, balances: holder.balances)
}

/// Shows each row's balance line, then checks saved keys when the page loads and a key once it is saved.
private func linuxRefreshBalances(
    after action: Int32, name: String, rows: [DesktopAPIKeyRow], balances: DesktopProviderBalances
) async {
    await balances.show(rows)
    if action == Int32(JSTI_LINUX_API_KEY_REFRESH) {
        await balances.refreshSaved()
    } else if action == Int32(JSTI_LINUX_API_KEY_SAVE) {
        await balances.refresh(credentialIdentifier: name)
    }
}

/// Runs one admitted API Keys action; nil means the native action code is unsupported.
private func linuxAPIKeyStatus(
    _ action: Int32, name: String, typed: String, controller: LinuxAppController
) async -> String? {
    switch action {
    case Int32(JSTI_LINUX_API_KEY_REFRESH): return ""
    case Int32(JSTI_LINUX_API_KEY_SAVE): return await controller.saveAPIKey(identifier: name, key: typed)
    case Int32(JSTI_LINUX_API_KEY_REMOVE): return await controller.removeAPIKey(identifier: name)
    case Int32(JSTI_LINUX_API_KEY_VALIDATE): return await controller.validateAPIKey(identifier: name, typed: typed)
    default: return nil
    }
}
