import Foundation
import SpeakDesktop
import CLinuxSupport

public enum LinuxObservationalDelivery: Equatable, Sendable {
    case unavailableBeforeDispatch
    case observedSpan
    case indeterminateAfterDispatch
}

public protocol LinuxObservationalInsertion: DesktopCorrectionReadback {
    func insert(_ text: String) -> LinuxObservationalDelivery
}

/// An opaque lease; every D-Bus operation stays on its owned native worker.
public final class LinuxAtspiTarget: LinuxObservationalInsertion, Equatable, @unchecked Sendable {
    private let handle: OpaquePointer
    public let provenance = DesktopCorrectionProvenance.observationalATSPISpan
    public let application: String? = "AT-SPI observational target"
    public var isCurrent: Bool { jsti_atspi_is_current(handle) == 1 }

    private init(_ handle: OpaquePointer) { self.handle = handle }
    deinit {
        jsti_atspi_cancel(handle)
        jsti_atspi_release(handle)
    }

    static func contractSelfTest() -> Int32 { jsti_atspi_contract_self_test() }
    static func pendingControlsContractSelfTest() -> Int32 { jsti_vocabulary_learning_controls_contract_self_test() }

    public static func == (lhs: LinuxAtspiTarget, rhs: LinuxAtspiTarget) -> Bool { lhs === rhs }

    @discardableResult
    public static func setSessionConsent(_ allowed: Bool, token: UInt64?) -> Bool {
        jsti_atspi_observational_consent(allowed ? 1 : 0, token ?? 0) == 1
    }

    public static func consentActionIsCurrent(_ allowed: Bool, token: UInt64) -> Bool {
        jsti_atspi_consent_action_is_current(allowed ? 1 : 0, token) == 1
    }

    public static func captureAdmitted() -> LinuxAtspiTarget? {
        jsti_atspi_capture().map { LinuxAtspiTarget($0) }
    }

    public static var availability: String {
        switch jsti_atspi_observational_status() {
        case 0: return "Observational learning is off."
        case 1: return "Checking the already-enabled accessibility bus; no text has been sampled."
        case 2: return "AT-SPI is ready. Only a newly admitted ordinary editable control can be observed."
        case 4: return "AT-SPI registration cleanup failed. Observational learning stopped and its private "
            + "connection is closing; no text sampling is permitted."
        case 5: return "This installed AT-SPI registry has an unsupported cleanup contract. Observational "
            + "learning is unavailable; nothing was registered or sampled."
        default: return "AT-SPI is unavailable or disabled on this desktop. No accessibility setting was changed. "
            + "Stop and allow again after enabling accessibility yourself; paste remains unconfirmed."
        }
    }

    public func insert(_ text: String) -> LinuxObservationalDelivery {
        guard Self.inputIsRepresentable(text) else {
            return .unavailableBeforeDispatch
        }
        switch text.withCString({ jsti_atspi_insert(handle, $0) }) {
        case 0: return .unavailableBeforeDispatch
        case 1: return .observedSpan
        default: return .indeterminateAfterDispatch
        }
    }

    static func inputIsRepresentable(_ text: String) -> Bool {
        !text.isEmpty && !text.contains("\0") && text.unicodeScalars.count <= 8192 && text.utf8.count <= 32768
    }

    public func begin(original: String) throws {
        guard original.withCString({ jsti_atspi_begin(handle, $0) }) == 1 else {
            throw LinuxNativeError(message: "The observational span is no longer eligible.")
        }
    }

    public func read() throws -> String {
        var bytes = [CChar](repeating: 0, count: 32769)
        guard jsti_atspi_read(handle, &bytes, bytes.count) == 1 else {
            throw LinuxNativeError(message: "The target, focus, privacy state or observational span changed.")
        }
        return String(cString: bytes)
    }

    public func cancel() { jsti_atspi_cancel(handle) }
}
