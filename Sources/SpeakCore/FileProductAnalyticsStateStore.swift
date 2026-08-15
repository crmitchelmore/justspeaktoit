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
    public func resetState() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func withState<T>(_ body: (State) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(readState())
    }

    private func updateState(_ body: (inout State) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var state = readState()
        try body(&state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // `completeUntilFirstUserAuthentication` keeps consent state readable from a locked or
        // background launch after the first unlock, matching the history store's convention.
        // Stricter `.completeFileProtection` would make every background read fail.
        try JSONEncoder().encode(state).write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// Reads persisted state, treating an unreadable or corrupt file as "nothing recorded yet".
    /// This fails closed: a defaulted `State` carries `.unknown` consent and no installation ID,
    /// so a damaged file can never enable collection — and can never permanently wedge start-up.
    private func readState() -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }
}
