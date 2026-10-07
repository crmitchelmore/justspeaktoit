import Foundation
import SpeakCore

/// The window's colour scheme, as the Mac's Appearance setting offers it:
/// follow the system, or always light or always dark.
public enum DesktopAppearance: Int, Codable, Sendable, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2
}

/// Totals shown on the desktop dashboard and History header, counted the way
/// the Mac's `HistoryStatistics` counts them: every record is a session, a
/// record whose transcription or post-processing failed is a session with an
/// error, and recording time and spend come from the saved transcription.
public struct DesktopHistoryInsights: Equatable, Sendable {
    public var sessions: Int
    public var sessionsWithErrors: Int
    public var recordingDuration: TimeInterval
    public var spend: Decimal

    public static let empty = DesktopHistoryInsights(
        sessions: 0, sessionsWithErrors: 0, recordingDuration: 0, spend: 0
    )

    public init(sessions: Int, sessionsWithErrors: Int, recordingDuration: TimeInterval, spend: Decimal) {
        self.sessions = sessions
        self.sessionsWithErrors = sessionsWithErrors
        self.recordingDuration = recordingDuration
        self.spend = spend
    }

    public init<Records: Sequence>(records: Records) where Records.Element == DesktopRecordingStore.Record {
        self = .empty
        for record in records {
            sessions += 1
            if record.failure != nil || record.postProcessingFailure != nil { sessionsWithErrors += 1 }
            if let duration = record.result?.duration, duration.isFinite, duration > 0 {
                recordingDuration += duration
            }
            if let cost = record.result?.cost?.totalCost, cost > 0 { spend += cost }
        }
    }

    public var averageSessionLength: TimeInterval {
        sessions > 0 ? recordingDuration / Double(sessions) : 0
    }
}

/// Text for History figures, formatted exactly as the Mac dashboard, History
/// header and History rows format them.
public enum DesktopHistoryFormat {
    /// "—" when nothing was recorded, otherwise minutes and seconds, "07m 05s".
    public static func totalDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "—" }
        let seconds = Int(interval)
        return String(format: "%02dm %02ds", seconds / 60, seconds % 60)
    }

    /// "—" when nothing was spent, otherwise a two-decimal amount in
    /// `currency`; less than a cent reads "<$0.01" rather than rounding to zero.
    public static func spend(_ amount: Decimal, currency: String = "USD", locale: Locale = .current) -> String {
        guard amount > 0 else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.isEmpty ? "USD" : currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let cent = Decimal(string: "0.01")!
        guard amount >= cent else { return "<" + (formatter.string(from: cent as NSDecimalNumber) ?? "0.01") }
        return formatter.string(from: amount as NSDecimalNumber) ?? "—"
    }

    /// A recording's audio length with hundredths, "07.24" or "01:07.24".
    public static func audioLength(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "—" }
        let hundredths = Int((interval * 100).rounded())
        let minutes = hundredths / 6000
        let seconds = (hundredths / 100) % 60
        let fraction = hundredths % 100
        return minutes > 0
            ? String(format: "%02d:%02d.%02d", minutes, seconds, fraction)
            : String(format: "%02d.%02d", seconds, fraction)
    }

    /// When a recording was made, as a medium date and short time.
    public static func created(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// What a History row shows, shared by the Windows and Linux windows so both
/// describe a recording in the same words as each other and the Mac.
public struct DesktopHistoryRowSummary: Equatable, Sendable {
    public enum Tone: Int32, Sendable {
        case normal = 0
        /// The transcription or post-processing failed.
        case failed = 1
        /// Saved, but not yet transcribed.
        case pending = 2
    }

    public let id: UUID
    /// "Sep 8, 2026 at 6:41 PM".
    public let created: String
    /// Audio length, "24.00", or nil when unknown.
    public let audioLength: String?
    /// Transcription cost, or nil when the provider reported none.
    public let cost: String?
    /// The transcript shown (processed first), the failure, or a pending note:
    /// a single line of at most `previewLimit` characters.
    public let preview: String
    /// "Whisper Tiny (on-device)", or "OpenAI Whisper • Post-processing: GPT-5 mini".
    public let models: String
    /// "From your Mac" for a synced transcript, "Profile: Code" for a profile.
    public let context: String?
    public let tone: Tone

    public static let previewLimit = 240

    public init(
        _ record: DesktopRecordingStore.Record, locale: Locale = .current, timeZone: TimeZone = .current,
        modelName: (String) -> String = DesktopHistorySearch.modelDisplayName(for:)
    ) {
        id = record.id
        created = DesktopHistoryFormat.created(record.createdAt, locale: locale, timeZone: timeZone)
        audioLength = record.result.flatMap { $0.duration > 0 ? DesktopHistoryFormat.audioLength($0.duration) : nil }
        cost = record.result?.cost.flatMap { cost in
            guard cost.totalCost > 0 else { return nil }
            return DesktopHistoryFormat.spend(cost.totalCost, currency: cost.currency, locale: locale)
        }
        let text: String
        if let failure = record.failure {
            text = failure
            tone = .failed
        } else if let failure = record.postProcessingFailure {
            text = "Post-processing failed: \(failure)"
            tone = .failed
        } else if let transcript = record.displayText {
            text = transcript.isEmpty ? "No speech was detected." : transcript
            tone = .normal
        } else {
            text = "Recording saved; awaiting transcription."
            tone = .pending
        }
        preview = Self.singleLine(text, limit: Self.previewLimit)
        var models = modelName(record.modelIdentifier)
        if let polish = record.postProcessingModelIdentifier {
            models += " • Post-processing: \(modelName(polish))"
        }
        self.models = models
        if record.isSyncedCopy {
            context = "From \(DesktopRecordingStore.Record.originName(record.originPlatform))"
        } else {
            context = record.profileName.map { "Profile: \($0)" }
        }
    }

    static func singleLine(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

public extension DesktopRecordingStore.Record {
    /// A friendly name for the device a synced transcript came from.
    static func originName(_ platform: String?) -> String {
        switch platform {
        case "macos": return "your Mac"
        case "ios": return "your iPhone"
        case "windows": return "another PC"
        case "linux": return "a Linux computer"
        default: return "another device"
        }
    }
}
