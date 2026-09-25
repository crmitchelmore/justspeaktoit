import CloudKit
import Foundation
import SpeakCore

@MainActor
public protocol ComparisonSyncDelegate: AnyObject {
    func pendingRevisions() -> [ModelComparisonRevision]
    func applyRemoteRevision(_ revision: ModelComparisonRevision) async throws
    func acknowledgeRevisions(_ revisions: [ModelComparisonRevision]) async throws
    func applyLegacyDeletion(id: UUID) async throws
}

/// One serialized reconciliation path handles local writes, retry and remote changes.
///
/// The pass itself is the shared `ComparisonSyncCoordinator`, run on the main
/// actor; this class supplies the native CloudKit transport and publishes status.
@MainActor
public final class ComparisonSyncEngine: ObservableObject {
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastError: Error?
    @Published public private(set) var lastSyncTime: Date?
    public static let shared = ComparisonSyncEngine()
    public static let syncTokenKey = "speak.sync.comparison.serverChangeToken"
    static let maxCoalescedPasses = ComparisonSyncCoordinator.maxCoalescedPasses

    private weak var delegate: ComparisonSyncDelegate?
    private let coordinator: ComparisonSyncCoordinator
    private let statusMirror: StatusMirror

    private convenience init() {
        self.init(transport: CloudKitComparisonSyncTransport(), defaults: .standard, cloudAvailability: {
            guard SyncConfiguration.hasCloudKitEntitlement else { return false }
            return (try? await SyncConfiguration.container?.accountStatus()) == .available
        })
    }

    init(transport: ComparisonSyncTransport, defaults: UserDefaults, cloudAvailability: @escaping () async -> Bool) {
        let mirror = StatusMirror()
        statusMirror = mirror
        coordinator = ComparisonSyncCoordinator(
            transport: transport,
            tokenStore: UserDefaultsSyncChangeTokenStore(defaults: defaults, key: Self.syncTokenKey),
            cloudAvailability: cloudAvailability,
            isChangeTokenExpired: { ($0 as? CKError)?.code == .changeTokenExpired },
            observer: mirror
        )
        mirror.engine = self
    }

    public func initialize(delegate: ComparisonSyncDelegate) async { self.delegate = delegate }

    public func sync() async {
        await coordinator.sync(store: delegate.map(DelegateComparisonStore.init))
    }

    fileprivate func apply(_ status: ComparisonSyncStatus, changed field: ComparisonSyncStatus.Field) {
        switch field {
        case .isSyncing: isSyncing = status.isSyncing
        case .lastError: lastError = status.lastError
        case .lastSyncTime: lastSyncTime = status.lastSyncTime
        }
    }
}

/// Publishes each coordinator assignment through the engine's properties.
@MainActor
private final class StatusMirror: ComparisonSyncStatusObserver {
    weak var engine: ComparisonSyncEngine?

    func comparisonSync(_ status: ComparisonSyncStatus, didChange field: ComparisonSyncStatus.Field) async {
        engine?.apply(status, changed: field)
    }
}

/// Holds the delegate for the duration of one coordinator call.
@MainActor
private final class DelegateComparisonStore: ComparisonSyncStore {
    private let delegate: ComparisonSyncDelegate

    init(_ delegate: ComparisonSyncDelegate) {
        self.delegate = delegate
    }

    func pendingRevisions() async -> [ModelComparisonRevision] {
        delegate.pendingRevisions()
    }

    func applyRemoteRevision(_ revision: ModelComparisonRevision) async throws {
        try await delegate.applyRemoteRevision(revision)
    }

    func acknowledgeRevisions(_ revisions: [ModelComparisonRevision]) async throws {
        try await delegate.acknowledgeRevisions(revisions)
    }

    func applyLegacyDeletion(id: UUID) async throws {
        try await delegate.applyLegacyDeletion(id: id)
    }
}
