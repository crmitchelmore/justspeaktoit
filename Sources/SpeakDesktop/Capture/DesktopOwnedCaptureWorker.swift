import Foundation

package struct DesktopOwnedCaptureReceipt: Sendable {
    package let producerQuiesced: Bool
    package let callbacksDrained: Bool
    package let resourcesRetired: Bool
    package let audioFailure: String?

    package init(
        producerQuiesced: Bool, callbacksDrained: Bool, resourcesRetired: Bool, audioFailure: String? = nil
    ) {
        self.producerQuiesced = producerQuiesced
        self.callbacksDrained = callbacksDrained
        self.resourcesRetired = resourcesRetired
        self.audioFailure = audioFailure
    }
}

/// Deliberately non-Sendable: native handles never leave the owning I/O actor.
package protocol DesktopOwnedCaptureDriver: AnyObject {
    func open(bridge: DesktopOwnedCaptureCallbackBridge) throws
    func quiesce() throws -> DesktopOwnedCaptureReceipt
    func retire() throws -> DesktopOwnedCaptureReceipt
}

package protocol DesktopOwnedCaptureDriverFactory: Sendable {
    associatedtype Driver: DesktopOwnedCaptureDriver
    /// Construction must not allocate native resources or perform I/O.
    func makeDriver() -> Driver
}

package actor DesktopOwnedCaptureWorker<Factory: DesktopOwnedCaptureDriverFactory>: DesktopPressCaptureQuiescingWorker {
    private nonisolated let executor = DesktopCaptureIOExecutor()
    package nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private struct Run {
        let driver: Factory.Driver
        let bridge: DesktopOwnedCaptureCallbackBridge
    }

    private let factory: Factory
    private var run: Run?
    private var lifetime: DesktopOwnedCaptureWorker?

    package init(factory: Factory) { self.factory = factory }

    package func open(
        id: UUID, identity: DesktopPressCaptureIdentity,
        receive: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        guard run == nil else { throw DesktopPressCaptureError.occupied }
        guard [16000, 24000].contains(identity.sampleRate), [20, 100].contains(identity.frameMilliseconds) else {
            throw DesktopPressCaptureError.invalidConfiguration
        }
        try identity.validate()
        let bridge = DesktopOwnedCaptureCallbackBridge(
            id: id, identity: identity, receive: receive, onFailure: onFailure
        )
        let driver = factory.makeDriver()
        run = Run(driver: driver, bridge: bridge)
        lifetime = self
        // A failed or cancelled open retains its partial owner until explicit close.
        try driver.open(bridge: bridge)
    }

    package func quiesce(id: UUID) async throws {
        let current = try currentRun(id)
        let receipt = try current.driver.quiesce()
        if let failure = receipt.audioFailure { current.bridge.fail(failure) }
        guard receipt.producerQuiesced, receipt.callbacksDrained else {
            throw DesktopPressCaptureError.captureFailed("Native producer has not acknowledged its final callbacks.")
        }
        if let failure = receipt.audioFailure { throw DesktopPressCaptureError.captureFailed(failure) }
    }

    package func close(id: UUID) async throws {
        let current = try currentRun(id)
        let receipt = try current.driver.retire()
        if let failure = receipt.audioFailure { current.bridge.fail(failure) }
        guard receipt.resourcesRetired, receipt.producerQuiesced, receipt.callbacksDrained else {
            throw DesktopPressCaptureError.cleanupFailed(
                "Native resources remain owned; explicit cleanup retry is required."
            )
        }
        run = nil
        lifetime = nil
    }

    private func currentRun(_ id: UUID) throws -> Run {
        guard let run, run.bridge.id == id else { throw DesktopPressCaptureError.staleLease }
        return run
    }
}
