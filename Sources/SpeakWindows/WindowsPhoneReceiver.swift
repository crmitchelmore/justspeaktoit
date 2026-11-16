import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform
import CWindowsSupport

/// Send from phone (F46) for the window: the shared receiver
/// (`DesktopHostPhoneReceiver`) with a Winsock listener, Windows' own DNS-SD
/// responder, Credential Manager for the state key and the Send from phone
/// dialog on the iCloud Sync page.
typealias WindowsPhoneReceiver = DesktopHostPhoneReceiver<WindowsHostPlatform>

/// Whether the dialog may still be handed this window's context. `present`
/// runs on the receiver's threads, so detaching takes the same lock: once
/// `detach` returns no snapshot can re-attach the context.
final class WindowsPhoneReceiverLink: @unchecked Sendable {
    private let lock = NSLock()
    private var attached = true
    let context: UnsafeMutableRawPointer

    init(context: UnsafeMutableRawPointer) {
        self.context = context
    }

    func whileAttached(_ body: (UnsafeMutableRawPointer) -> Void) {
        lock.withLock { if attached { body(context) } }
    }

    func detach() {
        lock.withLock {
            attached = false
            jsti_window_clear_phone_receiver()
        }
    }
}

extension DesktopHostPhoneReceiver where Platform == WindowsHostPlatform {
    /// Creates and starts the receiver for a running (not smoke-test) window.
    /// It listens only when the user has turned it on.
    static func configure(_ holder: WindowsEventContext) {
        guard !holder.smokeTest else { return }
        let link = WindowsPhoneReceiverLink(context: holder.callbackContext)
        holder.phoneReceiverLink = link
        let controller = holder.controller
        let receiver = WindowsPhoneReceiver(
            controller: controller,
            vault: WindowsCredentialVault(),
            native: DesktopHostPhoneReceiverNative(
                endpoints: DesktopTransportEndpoints(
                    makeListener: { try WindowsTransportListener() },
                    makeAdvertiser: { WindowsDNSServiceAdvertiser() }
                ),
                // The paste goes where the focus is when the transcript arrives.
                captureTarget: { try? WindowsInsertionTarget.capture() },
                present: { status in WindowsPhoneReceiver.present(status, link: link) },
                prepareDirectory: { try WindowsHostPlatform.preparePrivateDirectory($0) }
            )
        )
        holder.phoneReceiver = receiver
        receiver.start()
    }

    /// Stops listening and withdraws the announcement, then detaches the
    /// dialog, before the window's context can be released.
    static func shutDown(_ holder: WindowsEventContext) async {
        await holder.phoneReceiver?.shutDown()
        holder.phoneReceiverLink?.detach()
    }

    /// Hands the dialog its state, from any thread.
    private static func present(_ status: DesktopTransportReceiverStatus, link: WindowsPhoneReceiverLink) {
        let ids = status.devices.map { strdup($0.id) }
        let names = status.devices.map { strdup($0.name) }
        defer { (ids + names).forEach { free($0) } }
        let idPointers: [UnsafePointer<CChar>?] = ids.map { UnsafePointer($0) }
        let namePointers: [UnsafePointer<CChar>?] = names.map { UnsafePointer($0) }
        let code = status.enabled ? status.pairingCode : ""
        link.whileAttached { context in
            status.summary.withCString { text in
                code.withCString { pairing in
                    idPointers.withUnsafeBufferPointer { idBuffer in
                        namePointers.withUnsafeBufferPointer { nameBuffer in
                            var view = JSTIPhoneReceiverView(
                                status: text,
                                pairing_code: pairing,
                                available: 1,
                                enabled: status.enabled ? 1 : 0,
                                device_count: Int32(status.devices.count),
                                device_ids: idBuffer.baseAddress,
                                device_names: nameBuffer.baseAddress
                            )
                            _ = jsti_window_set_phone_receiver(&view, phoneReceiverEvent, context)
                        }
                    }
                }
            }
        }
    }
}

/// The Send from phone dialog's actions, on the UI thread: 1 turn receiving
/// on (value 1) or off, 2 new pairing code, 3 forget `deviceID`.
func phoneReceiverEvent(
    _ action: Int32, _ value: Int32, _ deviceID: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let holder = NativeCallbackContext<WindowsEventContext>.resolve(context) else { return }
    switch action {
    case 1: holder.phoneReceiver?.handle(.setEnabled(value == 1))
    case 2: holder.phoneReceiver?.handle(.newPairingCode)
    case 3:
        guard let deviceID else { return }
        holder.phoneReceiver?.handle(.forgetDevice(id: String(cString: deviceID)))
    default: break
    }
}

/// A Winsock listener on every interface for phones.
final class WindowsTransportListener: DesktopTransportListener {
    private var handle: OpaquePointer?
    let port: UInt16

    init() throws {
        var bound: UInt16 = 0
        var error = [CChar](repeating: 0, count: 512)
        guard let listener = jsti_transport_listen(0, &bound, &error, error.count) else {
            throw DesktopTransportError(String(cString: error))
        }
        handle = listener
        port = bound
    }

    deinit { close() }

    func accept(timeoutMilliseconds: Int32) -> DesktopTransportAccept {
        guard let handle else { return .closed }
        var connection: OpaquePointer?
        switch jsti_transport_accept(handle, timeoutMilliseconds, &connection) {
        case 1:
            guard let connection else { return .timedOut }
            return .connection(WindowsTransportConnection(handle: connection))
        case 0: return .timedOut
        default: return .closed
        }
    }

    func close() {
        guard let handle else { return }
        self.handle = nil
        jsti_transport_listener_destroy(handle)
    }
}

/// One accepted phone connection over Winsock.
final class WindowsTransportConnection: DesktopTransportConnection {
    private var handle: OpaquePointer?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { close() }

    func read(maxBytes: Int, timeoutMilliseconds: Int32) -> DesktopTransportRead {
        guard let handle, maxBytes > 0 else { return .closed }
        var buffer = [UInt8](repeating: 0, count: min(maxBytes, 64 * 1024))
        let count = buffer.withUnsafeMutableBufferPointer { bytes in
            jsti_transport_read(handle, bytes.baseAddress, Int32(bytes.count), timeoutMilliseconds)
        }
        if count > 0 { return .data(Data(buffer[0..<Int(count)])) }
        return count == 0 ? .timedOut : .closed
    }

    func write(_ data: Data) -> Bool {
        guard let handle else { return false }
        return data.withUnsafeBytes { bytes in
            jsti_transport_write(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == 0
        }
    }

    func close() {
        guard let handle else { return }
        self.handle = nil
        jsti_transport_connection_destroy(handle)
    }
}

/// Announces the receiver through Windows' own mDNS responder. Each `start`
/// replaces any earlier announcement.
final class WindowsDNSServiceAdvertiser: DesktopTransportAdvertiser {
    private var service: OpaquePointer?

    func start(name: String, type: String, port: UInt16) throws -> String {
        stop()
        var error = [CChar](repeating: 0, count: 512)
        guard let registered = jsti_dns_service_register(name, type, port, &error, error.count) else {
            throw DesktopTransportError(String(cString: error))
        }
        service = registered
        return name
    }

    func stop() {
        guard let service else { return }
        self.service = nil
        jsti_dns_service_unregister(service)
    }

    deinit { stop() }
}
