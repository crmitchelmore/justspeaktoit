import Foundation
import SpeakCore
import SpeakDesktop
import SpeakSync

/// Requests run outside the non-reentrant session gate; only local conditional commits hold it.
final class DesktopComparisonSyncPass: ComparisonSyncTransport, ComparisonSyncStore, SyncChangeTokenStore, Sendable {
    private let transport: CloudKitWebComparisonSyncTransport
    private let fence: CloudKitWebSessionFence
    private let state: DesktopCloudSyncStateStore
    private let store: DesktopComparisonStore
    private let account: String
    private let consentRevision: UInt64

    init(
        transport: CloudKitWebComparisonSyncTransport, fence: CloudKitWebSessionFence,
        state: DesktopCloudSyncStateStore, store: DesktopComparisonStore, scope: DesktopComparisonSyncScope
    ) {
        self.transport = transport; self.fence = fence; self.state = state; self.store = store
        account = scope.account; consentRevision = scope.consentRevision
    }

    private func requireConsent() async throws {
        try requireState(await state.current)
        try await state.requireComparisonConsent(revision: consentRevision)
    }

    private func requireState(_ current: DesktopCloudSyncState) throws {
        try Task.checkCancellation()
        guard current.boundAccount == account else { throw CloudKitWebServicesError.sessionChanged }
        guard current.enabledFeatures.contains(.comparisonRounds) else {
            throw CloudKitWebServicesError.consentRequired(.comparisonRounds)
        }
    }

    func check() async throws {
        try await fence.admit(isolation: #isolation) { try await self.requireConsent() }
    }

    func fetchChanges(after tokenData: Data?) async throws -> ComparisonChangePage {
        try await check()
        let page = try await transport.fetchChanges(after: tokenData)
        try await check()
        return page
    }

    func upload(revisions: [ModelComparisonRevision]) async -> ComparisonUploadResult {
        do {
            try await fence.admit(isolation: #isolation) {
                try await self.requireConsent()
                try await self.state.updateComparison(revision: self.consentRevision) { state in
                    try self.requireState(state)
                    var owners = state.comparisonOwners ?? [:]
                    for revision in revisions {
                        guard owners[revision.id] == nil || owners[revision.id] == self.account else {
                            throw DesktopCloudSyncError.unavailable("A comparison belongs to another iCloud account.")
                        }
                        guard revision.round != nil || owners[revision.id] == self.account else {
                            throw DesktopCloudSyncError.unavailable("An unsynced comparison deletion remains local.")
                        }
                        owners[revision.id] = self.account
                    }
                    state.comparisonOwners = owners
                }
            }
            let result = await transport.upload(revisions: revisions)
            try await check()
            return result
        } catch {
            return ComparisonUploadResult(failures: Dictionary(
                revisions.map { ($0.id, error) }, uniquingKeysWith: { first, _ in first }
            ))
        }
    }

    func pendingRevisions() async -> [ModelComparisonRevision] {
        let revisions = await store.revisions()
        let current = await state.current
        let owners = current.comparisonOwners ?? [:]
        let acknowledged = current.comparisonAcknowledgements ?? [:]
        return revisions.filter {
            (owners[$0.id] == account || ($0.round != nil && owners[$0.id] == nil))
                && acknowledged[$0.id] != $0.updatedAt
        }
    }

    func applyRemoteRevision(_ revision: ModelComparisonRevision) async throws {
        try await fence.admit(isolation: #isolation) {
            try await self.requireConsent()
            try await self.claim(revision.id)
            try await self.requireConsent()
            try await self.store.applyRemoteRevision(revision)
            try await self.state.updateComparison(revision: self.consentRevision) { state in
                try self.requireState(state)
                var acknowledgements = state.comparisonAcknowledgements ?? [:]
                acknowledgements[revision.id] = revision.updatedAt
                state.comparisonAcknowledgements = acknowledgements
            }
        }
    }

    func acknowledgeRevisions(_ revisions: [ModelComparisonRevision]) async throws {
        try await fence.admit(isolation: #isolation) {
            try await self.requireConsent()
            let current = await self.store.revisions()
            let matched = revisions.filter { current.contains($0) }
            try await self.store.acknowledgeRevisions(matched)
            try await self.state.updateComparison(revision: self.consentRevision) { state in
                try self.requireState(state)
                var acknowledgements = state.comparisonAcknowledgements ?? [:]
                for revision in matched { acknowledgements[revision.id] = revision.updatedAt }
                state.comparisonAcknowledgements = acknowledgements
            }
        }
    }

    func applyLegacyDeletion(id: UUID) async throws {
        try await fence.admit(isolation: #isolation) {
            try await self.requireConsent()
            try await self.claim(id)
            try await self.requireConsent()
            try await self.store.applyLegacyDeletion(id: id)
        }
    }

    private func claim(_ id: UUID) async throws {
        try await state.updateComparison(revision: consentRevision) { state in
            try requireState(state)
            var owners = state.comparisonOwners ?? [:]
            guard owners[id] == nil || owners[id] == account else {
                throw DesktopCloudSyncError.unavailable("A comparison belongs to another iCloud account.")
            }
            owners[id] = account
            state.comparisonOwners = owners
        }
    }

    func loadChangeToken() async throws -> Data? {
        try await fence.admit(isolation: #isolation) {
            try await self.requireConsent()
            return await self.state.current.comparisonCursor
        }
    }

    func saveChangeToken(_ token: Data) async throws {
        try await fence.admit(isolation: #isolation) {
            try await self.requireConsent()
            try await self.state.updateComparison(revision: self.consentRevision) {
                try self.requireState($0)
                $0.comparisonCursor = token
            }
        }
    }

    func clearChangeToken() async throws {
        try await fence.admit(isolation: #isolation) {
            try await self.requireConsent()
            try await self.state.updateComparison(revision: self.consentRevision) {
                try self.requireState($0)
                $0.comparisonCursor = nil
            }
        }
    }
}
