#if os(iOS)
import CoreFoundation
import Foundation
import UIKit
import UniformTypeIdentifiers

enum TranscriptClipboardLifetime: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    static let defaultValue = TranscriptClipboardLifetime.fiveMinutes

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        }
    }

    static func decode(_ value: Any?) -> TranscriptClipboardLifetime {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              let lifetime = TranscriptClipboardLifetime(rawValue: number.intValue) else {
            return .defaultValue
        }
        return lifetime
    }
}

struct TranscriptClipboardPolicy: Equatable, Sendable {
    let lifetime: TranscriptClipboardLifetime
    let allowsUniversalClipboard: Bool

    static let defaultValue = TranscriptClipboardPolicy(
        lifetime: .defaultValue,
        allowsUniversalClipboard: false
    )

    init(lifetime: TranscriptClipboardLifetime, allowsUniversalClipboard: Bool) {
        self.lifetime = lifetime
        self.allowsUniversalClipboard = allowsUniversalClipboard
    }

    init(storedLifetime: Any?, storedAllowsUniversalClipboard: Any?) {
        self.lifetime = TranscriptClipboardLifetime.decode(storedLifetime)
        self.allowsUniversalClipboard = Self.decodeBoolean(storedAllowsUniversalClipboard) ?? false
    }

    private static func decodeBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

@MainActor
protocol TranscriptPasteboard: AnyObject {
    var changeCount: Int { get }
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: TranscriptPasteboard {}

/// The sole transcript-writing boundary for the iOS general pasteboard.
///
/// The system owns expiry. This adapter never schedules a later clear, so a
/// newer item copied by another app cannot be removed by an old transcript.
@MainActor
final class TranscriptClipboard {
    static let shared = TranscriptClipboard(
        pasteboard: UIPasteboard.general,
        now: Date.init,
        policy: { AppSettings.shared.transcriptClipboardPolicy }
    )

    private let pasteboard: any TranscriptPasteboard
    private let now: () -> Date
    private let policy: () -> TranscriptClipboardPolicy

    init(
        pasteboard: any TranscriptPasteboard,
        now: @escaping () -> Date,
        policy: @escaping () -> TranscriptClipboardPolicy
    ) {
        self.pasteboard = pasteboard
        self.now = now
        self.policy = policy
    }

    @discardableResult
    func copy(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let policy = self.policy()
        let before = self.pasteboard.changeCount
        self.pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .expirationDate: self.now().addingTimeInterval(TimeInterval(policy.lifetime.rawValue)),
                .localOnly: !policy.allowsUniversalClipboard
            ]
        )
        return self.pasteboard.changeCount > before
    }
}
#endif
