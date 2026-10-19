import Foundation

/// Delivery evidence, separate from the localized status or successful key submission.
public struct DesktopTextOutputResult: Equatable, Sendable {
    public enum Disposition: Equatable, Sendable {
        case confirmedInsertion
        /// Target-bound AT-SPI observations, not acknowledged mutation causality.
        case observedInsertion
        case copied
        case unconfirmedInsertion
        case recoveryCopy
        case failed
        case cancelled
    }

    public let disposition: Disposition
    public let status: String

    public init(_ disposition: Disposition, status: String) {
        self.disposition = disposition
        self.status = status
    }

    public var permitsAutomaticResume: Bool {
        disposition == .confirmedInsertion || disposition == .copied
    }
}
