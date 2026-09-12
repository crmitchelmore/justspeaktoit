import Foundation

/// Both source-device UIs use this one-way flow: a single rendered step never
/// includes both the encrypted QR and its unlock code. Regeneration must create
/// a new transfer before resetting this presentation state.
public struct ConfigTransferPresentation: Equatable, Sendable {
    private let code: String
    public private(set) var isShowingQRCode = true
    public var visibleCode: String? { isShowingQRCode ? nil : code }

    public init(code: String) {
        self.code = code
    }

    /// The receiver must finish scanning before the source reveals this factor.
    /// There is deliberately no transition back to the same transfer's QR.
    public mutating func revealCode() {
        isShowingQRCode = false
    }

    public static let revealButtonTitle = "I’ve scanned the QR"
    public static let captureNotice = "Keep screen sharing and screen recording off during transfer."
    public static let expiryNotice = "Transfer timing depends on both devices’ clocks."
    public static let receiverInstruction =
        "On the source device, tap “I’ve scanned the QR”, then enter the revealed code here."
}
