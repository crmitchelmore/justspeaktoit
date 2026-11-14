import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopSync

/// The native pieces a host supplies around the shared phone receiver.
package struct DesktopHostPhoneReceiverNative<Platform: DesktopHostPlatform>: Sendable {
    /// The TCP listener and the DNS-SD advertiser.
    package var endpoints: DesktopTransportEndpoints
    /// The focused field when a transcript arrives, captured off the UI thread.
    package var captureTarget: @Sendable () -> Platform.InsertionTarget?
    /// Hands the Settings card its state, on any thread.
    package var present: @Sendable (DesktopTransportReceiverStatus) -> Void
    /// Creates the private state folder, only when there is something to save.
    package var prepareDirectory: @Sendable (URL) throws -> Void

    package init(
        endpoints: DesktopTransportEndpoints,
        captureTarget: @escaping @Sendable () -> Platform.InsertionTarget?,
        present: @escaping @Sendable (DesktopTransportReceiverStatus) -> Void,
        prepareDirectory: @escaping @Sendable (URL) throws -> Void
    ) {
        self.endpoints = endpoints
        self.captureTarget = captureTarget
        self.present = present
        self.prepareDirectory = prepareDirectory
    }
}

/// Receives transcripts from a paired phone (F46) for a host's window and
/// inserts each final one at the cursor. Windows and Linux run this same flow
/// and differ only in `DesktopHostPhoneReceiverNative`.
///
/// It is off until the user turns it on. That choice, the pairing code and the
/// device credentials live in a sealed file whose key is in the credential
/// vault, never in `settings.json`, so a restored Mac backup cannot open a
/// listener. Settings actions run on a private queue because starting the
/// listener and the advertiser blocks; transcripts reach the controller one
/// at a time in the order they arrived.
package final class DesktopHostPhoneReceiver<Platform: DesktopHostDefaultTextOutputPlatform>: @unchecked Sendable {
    /// What the user asked for in the Settings card.
    package enum Action: Sendable, Equatable {
        case setEnabled(Bool)
        case newPairingCode
        case forgetDevice(id: String)
    }

    private struct Arrival: Sendable {
        let delivery: DesktopTransportDelivery
        let target: Platform.InsertionTarget?
    }

    package let receiver: DesktopTransportReceiver
    private let queue = DispatchQueue(label: "com.justspeaktoit.desktop.phone-receiver")
    private let arrivals: AsyncStream<Arrival>.Continuation
    private let consumer: Task<Void, Never>
    private let lock = NSLock()
    private var stopped = false

    /// Where the sealed receiver state lives.
    package static func stateURL(in directory: URL) -> URL {
        directory.appendingPathComponent("PhoneReceiver").appendingPathComponent("state.sealed")
    }

    package init(
        controller: DesktopHostController<Platform>,
        vault: any DesktopCredentialVault,
        native: DesktopHostPhoneReceiverNative<Platform>
    ) {
        let storage = DesktopTransportReceiverStorage(
            fileURL: Self.stateURL(in: controller.directory),
            readKey: {
                guard let stored = try vault.readCredential(DesktopTransportReceiverStorage.credentialName) else {
                    return nil
                }
                return Data(base64Encoded: stored)
            },
            writeKey: { key in
                try vault.writeCredential(
                    key.base64EncodedString(), name: DesktopTransportReceiverStorage.credentialName
                )
            },
            prepareDirectory: native.prepareDirectory
        )
        let (stream, continuation) = AsyncStream<Arrival>.makeStream()
        arrivals = continuation
        let capture = native.captureTarget
        receiver = DesktopTransportReceiver(storage: storage, endpoints: native.endpoints) { delivery in
            continuation.yield(Arrival(delivery: delivery, target: capture()))
        }
        consumer = Task {
            for await arrival in stream {
                await controller.insertPhoneTranscript(
                    arrival.delivery.text, from: arrival.delivery.deviceName, target: arrival.target
                )
            }
        }
        let present = native.present
        receiver.setChangeHandler { [weak self] status in
            guard self?.isStopped == false else { return }
            present(status)
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    /// Reads the saved state and listens if the user turned the receiver on.
    package func start() {
        queue.async { [self] in
            guard !isStopped else { return }
            receiver.start()
        }
    }

    /// Runs a Settings action off the UI thread.
    package func handle(_ action: Action) {
        queue.async { [self] in
            guard !isStopped else { return }
            switch action {
            case .setEnabled(let enabled): receiver.setEnabled(enabled)
            case .newPairingCode: receiver.newPairingCode()
            case .forgetDevice(let id): receiver.forgetDevice(id: id)
            }
        }
    }

    /// Stops listening and advertising before the window's context goes away.
    /// Nothing reaches the Settings card afterwards and no new transcript is
    /// inserted; one already handed to the controller may still finish.
    package func shutDown() async {
        lock.withLock { stopped = true }
        receiver.setChangeHandler(nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [receiver] in
                receiver.shutDown()
                done.resume()
            }
        }
        arrivals.finish()
        consumer.cancel()
    }
}
