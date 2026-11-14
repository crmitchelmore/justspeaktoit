import Foundation

/// The native half of a desktop voice edit: one selection captured in another
/// app when the command ran. Hosts adapt their accessibility layer to this so
/// the capture, verification and recovery decisions stay shared and testable.
public protocol DesktopVoiceEditTarget: AnyObject, Sendable {
    /// Reads the captured selection once.
    func selectedText() async throws -> String
    /// Whether the captured field, selection and text are still unchanged.
    var isCurrent: Bool { get }
    /// Replaces only the captured selection, at most once, re-verifying the
    /// target before anything is dispatched.
    func replace(with text: String) async -> DesktopVoiceEditReplacement
    func copyToClipboard(_ text: String) throws
    func cancel()
}

public enum DesktopVoiceEditReplacement: Equatable, Sendable {
    case replaced
    /// Refused before anything was sent to the app; the field is unchanged.
    case refused(String)
    /// Sent to the app but not confirmed; the field may have changed.
    case indeterminate(String)
}

public enum DesktopVoiceEditOutcome: Equatable, Sendable {
    case replaced(String)
    case recovery(String)
}

public struct DesktopVoiceEditTargetError: LocalizedError, Equatable {
    public let message: String
    public let mayHaveReplaced: Bool

    public init(_ message: String, mayHaveReplaced: Bool = false) {
        self.message = message
        self.mayHaveReplaced = mayHaveReplaced
    }

    public var errorDescription: String? { message }
}

/// Never redirects: a rewrite goes only to the captured target, or to the
/// clipboard for the user to paste, with an honest account of which.
public enum DesktopVoiceEditDelivery {
    public static let replacedStatus = "Voice edit: the captured selection was replaced."
    public static let targetChanged = "The captured field, selection or text changed after the command ran."

    /// `unavailable` explains why nothing was captured, so the edit stops
    /// before the microphone opens.
    public static func capture(_ target: (any DesktopVoiceEditTarget)?, unavailable: String) async throws -> String {
        guard let target else { throw DesktopVoiceEditTargetError(unavailable) }
        let text = try await target.selectedText()
        guard !text.isEmpty else { throw DesktopVoiceEditError.emptyInput }
        return text
    }

    public static func replace(
        _ text: String, target: (any DesktopVoiceEditTarget)?, unavailable: String
    ) async throws -> DesktopVoiceEditOutcome {
        guard let target else { throw DesktopVoiceEditTargetError(unavailable) }
        try Task.checkCancellation()
        guard target.isCurrent else {
            return try recover(text, target: target, reason: targetChanged, ambiguous: false)
        }
        let result = await withTaskCancellationHandler {
            await target.replace(with: text)
        } onCancel: {
            target.cancel()
        }
        if result == .replaced { return .replaced(replacedStatus) }
        try Task.checkCancellation()
        switch result {
        case .replaced:
            return .replaced(replacedStatus)
        case .refused(let reason):
            return try recover(text, target: target, reason: reason, ambiguous: false)
        case .indeterminate(let reason):
            return try recover(text, target: target, reason: reason, ambiguous: true)
        }
    }

    private static func recover(
        _ text: String, target: any DesktopVoiceEditTarget, reason: String, ambiguous: Bool
    ) throws -> DesktopVoiceEditOutcome {
        do { try target.copyToClipboard(text) } catch {
            throw DesktopVoiceEditTargetError(
                "\(reason) The rewrite could not be copied either: \(error.localizedDescription)",
                mayHaveReplaced: ambiguous
            )
        }
        return .recovery(ambiguous
            ? "Voice edit may have reached the app. Rewrite copied; check the original before pasting. \(reason)"
            : "Voice edit was not applied. Rewrite copied for manual paste. \(reason)")
    }
}
