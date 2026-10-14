import Foundation
import SpeakCore

/// Composition binds this capability to the fixed app-owned ledger. The
/// revalidation closure captures the reader's opaque receipt, not write authority.
public struct DesktopVoiceUsageReadAccess: Sendable {
    public static let relativePath = "VoiceUsage/requests.json"

    public struct Source: Sendable {
        public let data: Data?
        private let validate: @Sendable () throws -> Void

        public init(data: Data?, revalidate: @escaping @Sendable () throws -> Void) {
            self.data = data
            self.validate = revalidate
        }

        public func revalidate() throws {
            try Task.checkCancellation()
            try validate()
            try Task.checkCancellation()
        }
    }

    private let reader: @Sendable (URL, Int) throws -> Source

    public init(read: @escaping @Sendable (URL, Int) throws -> Source) { self.reader = read }

    public func read(appDirectory: URL) throws -> Source {
        try Task.checkCancellation()
        let source = try reader(appDirectory, DesktopVoiceUsageLedger.maximumBytes)
        try Task.checkCancellation()
        guard (source.data?.count ?? 0) <= DesktopVoiceUsageLedger.maximumBytes else {
            throw DesktopVoiceUsageLedger.Failure.tooLarge
        }
        return source
    }

    public enum Failure: LocalizedError, Equatable {
        case changed

        public var errorDescription: String? { "The Voice usage source changed while it was being inspected." }
    }
}

/// Separate source evidence; this is not a migration manifest or import DTO.
public struct DesktopVoiceUsageSnapshot: Sendable {
    public enum Presence: Sendable, Equatable { case missing, accepted, invalid, unreadable, oversized, changed }

    public struct ActiveCapture: Sendable {
        public let records: [VoiceSynthesisUsage.Record]

        public init(records: [VoiceSynthesisUsage.Record]) { self.records = records }
    }

    public struct Memory: Sendable {
        public let loadedRecords: [VoiceSynthesisUsage.Record]?
        public let unsavedRecords: [VoiceSynthesisUsage.Record]
        public let activeCaptures: [ActiveCapture]
        public let loadFailed: Bool
        public let warning: String?
        public let omittedUnsavedObservations: Int
        public let unsavedProblem: String?

        public init(
            loadedRecords: [VoiceSynthesisUsage.Record]?, unsavedRecords: [VoiceSynthesisUsage.Record],
            activeCaptures: [ActiveCapture], loadFailed: Bool, warning: String?, omittedUnsavedObservations: Int,
            unsavedProblem: String? = nil
        ) {
            self.loadedRecords = loadedRecords
            self.unsavedRecords = unsavedRecords
            self.activeCaptures = activeCaptures
            self.loadFailed = loadFailed
            self.warning = warning
            self.omittedUnsavedObservations = omittedUnsavedObservations
            self.unsavedProblem = unsavedProblem
        }
    }

    public let presence: Presence
    public let originalBytes: Data?
    public let digest: String?
    public let acceptedLedger: DesktopVoiceUsageLedger?
    public let memory: Memory
    public let problem: String?
    private let source: DesktopVoiceUsageReadAccess.Source?

    /// Legacy writers can already have lost unknown members or observations.
    /// An injected point-in-time read cannot establish historical completeness.
    public var completenessLimitation: String {
        "Legacy usage may already have lost observations or unknown fields. "
            + "Active captures are point-in-time, unfinished observations. "
            + "Read receipts do not authorize overwrite or prove native end-to-end capture completeness."
    }

    public static func collect(
        appDirectory: URL, memory: Memory, access: DesktopVoiceUsageReadAccess, digests: LocalModelDigestProvider
    ) throws -> Self {
        let source: DesktopVoiceUsageReadAccess.Source
        do { source = try access.read(appDirectory: appDirectory) } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(presence: readFailure(error), originalBytes: nil, digest: nil, acceptedLedger: nil,
                         memory: memory, problem: error.localizedDescription, source: nil)
        }
        let digest = try source.data.map { try digests.sha256(of: $0) }
        var ledger: DesktopVoiceUsageLedger?
        var problem: String?
        if let bytes = source.data {
            do { ledger = try DesktopVoiceUsageLedger(validating: bytes) } catch is CancellationError {
                throw CancellationError()
            } catch { problem = error.localizedDescription }
        }
        do { try source.revalidate() } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(presence: .changed, originalBytes: source.data, digest: digest, acceptedLedger: nil,
                         memory: memory, problem: error.localizedDescription, source: source)
        }
        return .init(presence: source.data == nil ? .missing : (ledger == nil ? .invalid : .accepted),
                     originalBytes: source.data, digest: digest, acceptedLedger: ledger,
                     memory: memory, problem: problem, source: source)
    }

    public func revalidateSource() throws {
        guard let source else { throw Failure.unavailable }
        try source.revalidate()
    }

    /// Pure preparation only. A separately qualified owned-write contract must
    /// decide whether/how these bytes can replace the current native source.
    public func preparedAppend() throws -> Data {
        guard presence == .accepted || presence == .missing else { throw Failure.unavailable }
        guard memory.omittedUnsavedObservations == 0, memory.unsavedProblem == nil else {
            throw Failure.incompleteMemory
        }
        try revalidateSource()
        let base = try acceptedLedger ?? DesktopVoiceUsageLedger(validating: Data("[]".utf8))
        let proposed = try base.appending(memory.unsavedRecords)
        if let loaded = memory.loadedRecords, loaded != base.records,
           loaded != (try DesktopVoiceUsageLedger(validating: proposed).records) {
            throw Failure.unreconciledMemory
        }
        return proposed
    }

    private static func readFailure(_ error: Error) -> Presence {
        if error is DesktopVoiceUsageReadAccess.Failure { return .changed }
        return (error as? DesktopVoiceUsageLedger.Failure) == .tooLarge ? .oversized : .unreadable
    }

    public enum Failure: LocalizedError, Equatable {
        case unavailable, stateChanged, stillClosing, incompleteMemory, unreconciledMemory

        public var errorDescription: String? {
            switch self {
            case .unavailable: "The Voice usage source has no accepted read authority."
            case .stateChanged: "Voice usage changed during collection. No complete snapshot was returned."
            case .stillClosing: "The previous Voice usage collection is still closing."
            case .incompleteMemory:
                "Unsaved Voice observations could not all be retained; preparation is incomplete."
            case .unreconciledMemory: "Loaded Voice observations differ from the source and prepared append."
            }
        }
    }
}
