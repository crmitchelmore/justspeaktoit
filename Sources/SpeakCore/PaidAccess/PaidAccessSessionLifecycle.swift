import Foundation

/// Orders credential writes and fences work admitted by an earlier account session.
/// Shared by the two app managers; it does not decide entitlement or routing policy.
@MainActor
public final class PaidAccessSessionLifecycle {
    public private(set) var generation = UUID()

    private let client: any PaidAccessClienting
    private let store: any PaidAccessSessionStoring
    private var storageRevision = UUID()
    private var refreshTask: Task<PaidAccessSession?, Error>?
    private var mutation: (id: UUID, task: Task<Void, Never>)?

    public init(client: any PaidAccessClienting, store: any PaidAccessSessionStoring) {
        self.client = client
        self.store = store
    }

    public func currentSession() async throws -> PaidAccessSession? {
        let generation = self.generation
        await self.mutation?.task.value
        guard generation == self.generation else { return nil }
        let revision = self.storageRevision
        let stored = await self.store.loadSession()
        guard generation == self.generation else { return nil }
        guard revision == self.storageRevision else { return try await self.currentSession() }
        guard let stored else { return nil }
        guard stored.needsRefresh() else { return stored }
        guard stored.isRefreshable() else { throw PaidAccessError.notSignedIn }

        return try await self.refreshedSession(stored, generation: generation)
    }

    private func refreshedSession(_ stored: PaidAccessSession, generation: UUID) async throws -> PaidAccessSession? {
        guard generation == self.generation else { return nil }
        // Concurrent callers must share the one use of the rotating refresh token.
        if let refreshTask = self.refreshTask {
            let result = try await refreshTask.value
            return generation == self.generation ? result : nil
        }
        let task = Task { () throws -> PaidAccessSession? in
            do {
                let refreshed = try await self.client.refresh(session: stored)
                return try await self.saveSession(refreshed, generation: generation) ? refreshed : nil
            } catch PaidAccessError.notSignedIn {
                throw PaidAccessError.notSignedIn
            } catch {
                // A transient failure retains the existing fallback, but never
                // brings back credentials from an account the user signed out of.
                return generation == self.generation ? stored : nil
            }
        }
        self.refreshTask = task
        defer {
            if generation == self.generation { self.refreshTask = nil }
        }
        let result = try await task.value
        guard generation == self.generation else { return nil }
        return result
    }

    /// Commits an explicitly authenticated account under a fresh generation.
    /// Empty-store reads admitted while Apple sign-in was pending must not
    /// later overwrite the signed-in state after this commit.
    public func acceptSignIn(_ session: PaidAccessSession, generation: UUID) async throws -> UUID? {
        guard try await self.saveSession(session, generation: generation) else { return nil }
        guard generation == self.generation else {
            Task { [client] in await client.signOut(session: session) }
            return nil
        }
        self.generation = UUID()
        self.refreshTask?.cancel()
        self.refreshTask = nil
        return self.generation
    }

    /// Saves only for the admitting account generation. An already admitted
    /// async write is ordered before logout's clear, including injected stores
    /// which suspend inside saveSession. Later accounts queue after that clear.
    public func saveSession(_ session: PaidAccessSession, generation: UUID) async throws -> Bool {
        self.storageRevision = UUID()
        let previous = self.mutation?.task
        let id = UUID()
        let task = Task { () throws -> Bool in
            await previous?.value
            guard generation == self.generation else { return false }
            try await self.store.saveSession(session)
            return generation == self.generation
        }
        self.mutation = (id, Task { _ = try? await task.value })
        defer {
            if self.mutation?.id == id { self.mutation = nil }
        }
        let wrote: Bool
        do {
            wrote = try await task.value
        } catch {
            if generation != self.generation {
                Task { [client] in await client.signOut(session: session) }
            }
            throw error
        }
        let saved = wrote && generation == self.generation
        if !saved {
            // This task may be cancelled by logout. Revoke a late-issued token
            // in a fresh task; its completion never changes local credentials.
            Task { [client] in await client.signOut(session: session) }
        }
        return saved
    }

    /// Invalidates synchronously, before the caller can suspend. Returns the
    /// removed session for best-effort server revocation after local logout.
    public func clear() -> Task<PaidAccessSession?, Never> {
        self.generation = UUID()
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.storageRevision = UUID()
        let previous = self.mutation?.task
        let id = UUID()
        let task = Task {
            await previous?.value
            let stored = await self.store.loadSession()
            await self.store.clearSession()
            return stored
        }
        self.mutation = (id, Task {
            _ = await task.value
            if self.mutation?.id == id { self.mutation = nil }
        })
        return task
    }
}
