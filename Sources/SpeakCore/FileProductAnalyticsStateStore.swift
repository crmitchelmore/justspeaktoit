import Foundation

public final class FileProductAnalyticsStateStore: ProductAnalyticsStateStore, @unchecked Sendable {
    private struct State: Codable {
        var consent: AnalyticsConsentState = .unknown
        var installationID: UUID?
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }
    public func loadConsent() throws -> AnalyticsConsentState { try withState { $0.consent } }
    public func saveConsent(_ consent: AnalyticsConsentState) throws { try updateState { $0.consent = consent } }
    public func loadInstallationID() throws -> UUID? { try withState { $0.installationID } }
    public func saveInstallationID(_ id: UUID) throws { try updateState { $0.installationID = id } }
    public func deleteInstallationID() throws { try updateState { $0.installationID = nil } }

    private func withState<T>(_ body: (State) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(try readState())
    }

    private func updateState(_ body: (inout State) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var state = try readState()
        try body(&state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func readState() throws -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
    }
}
