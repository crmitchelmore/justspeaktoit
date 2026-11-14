import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// Send from phone (F46) for the window: the shared receiver
/// (`DesktopHostPhoneReceiver`) with a dual-stack POSIX listener, Avahi on the
/// system bus for DNS-SD, the Secret Service keyring and the Send from phone
/// group on the iCloud Sync page.
typealias LinuxPhoneReceiver = DesktopHostPhoneReceiver<LinuxHostPlatform>

extension DesktopHostPhoneReceiver where Platform == LinuxHostPlatform {
    /// Creates the receiver for a real (not smoke-test) window before it
    /// opens. It reads nothing and listens on nothing until `start`.
    static func configure(_ holder: LinuxEventContext) {
        guard !holder.smokeTest else { return }
        let controller = holder.controller
        holder.phoneReceiver = LinuxPhoneReceiver(
            controller: controller,
            vault: LinuxCredentialVault(),
            native: DesktopHostPhoneReceiverNative(
                endpoints: DesktopTransportEndpoints(
                    makeListener: { try DesktopPOSIXTransportListener() },
                    makeAdvertiser: { LinuxAvahiAdvertiser() }
                ),
                // The paste goes where the focus is when the transcript arrives.
                captureTarget: { LinuxEventContext.captureTarget(includeObservation: false) },
                present: { status in LinuxPhoneReceiver.present(status) },
                prepareDirectory: { try LinuxFiles.preparePrivateDirectory($0) }
            )
        )
    }

    /// Starts once the controller has loaded its settings, so an early
    /// transcript finds the user's output choice.
    static func start(_ holder: LinuxEventContext, after ready: Task<Void, Never>) {
        guard let receiver = holder.phoneReceiver else { return }
        Task {
            await ready.value
            receiver.start()
        }
    }

    /// Once the window has closed: stops listening and withdraws the
    /// announcement before the controller closes.
    static func shutDown(_ holder: LinuxEventContext) async {
        await holder.phoneReceiver?.shutDown()
    }

    /// Hands the Send from phone group its state, from any thread.
    private static func present(_ status: DesktopTransportReceiverStatus) {
        let ids = status.devices.map { strdup($0.id) }
        let names = status.devices.map { strdup($0.name) }
        defer { (ids + names).forEach { free($0) } }
        let idPointers: [UnsafePointer<CChar>?] = ids.map { UnsafePointer($0) }
        let namePointers: [UnsafePointer<CChar>?] = names.map { UnsafePointer($0) }
        let code = status.enabled ? status.pairingCode : ""
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
                        _ = jsti_window_set_phone_receiver(&view)
                    }
                }
            }
        }
    }
}

/// Announces the receiver through avahi-daemon. Each `start` replaces any
/// earlier announcement.
final class LinuxAvahiAdvertiser: DesktopTransportAdvertiser {
    private var service: OpaquePointer?

    func start(name: String, type: String, port: UInt16) throws -> String {
        stop()
        var error = [CChar](repeating: 0, count: 512)
        var announced = [CChar](repeating: 0, count: 256)
        guard let registered = jsti_dnssd_register(
            name, type, port, &announced, announced.count, &error, error.count
        ) else {
            throw DesktopTransportError(String(cString: error))
        }
        service = registered
        let published = String(cString: announced)
        return published.isEmpty ? name : published
    }

    func stop() {
        guard let service else { return }
        self.service = nil
        jsti_dnssd_unregister(service)
    }

    deinit { stop() }
}

/// The Send from phone group's events, on the GTK thread. Returns false for others.
func linuxPhoneReceiverEvent(
    _ event: DesktopNativeLinuxEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    let action: LinuxPhoneReceiver.Action
    switch event {
    case .phoneReceiverEnable: action = .setEnabled(slot != 0)
    case .phoneReceiverNewCode: action = .newPairingCode
    case .phoneReceiverForget: action = .forgetDevice(id: value)
    default: return false
    }
    holder.phoneReceiver?.handle(action)
    return true
}
