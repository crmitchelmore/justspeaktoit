import Foundation
import Speech

/// Capture can require existing system assets while explicit preparation may install them.
public enum AppleSpeechAssetPolicy: Sendable {
    case installedOnly
    case installIfNeeded
}

/// The asset-inventory states the install wait reacts to, mirrored off
/// `AssetInventory.Status` so the wait policy stays testable on any OS.
enum AppleSpeechAssetStatus: Sendable, Equatable {
    case unsupported
    case supported
    case downloading
    case installed
}

@available(macOS 26.0, iOS 26.0, *)
extension AppleSpeechAssetStatus {
    init(_ status: AssetInventory.Status) {
        switch status {
        case .unsupported: self = .unsupported
        case .supported: self = .supported
        case .downloading: self = .downloading
        case .installed: self = .installed
        @unknown default: self = .unsupported
        }
    }
}

/// What the asset-install wait loop should do after one inventory poll.
enum AppleSpeechAssetWaitStep: Sendable, Equatable {
    case installed
    case keepWaiting
    case giveUp
}

/// How long the SpeechAnalyzer asset wait tolerates each inventory state.
///
/// `.downloading` gets the full budget because a cold model download is slow.
/// `.supported` means "installable but not installing", which only resolves
/// itself while an install request is in flight — so it gets a short grace
/// window when one was issued, and no wait at all when none was, instead of
/// silently consuming the whole download budget before failing.
enum AppleSpeechAssetWaitPolicy {
    static let pollInterval = Duration.milliseconds(250)
    /// 120 × 250ms = 30s.
    static let maxPolls = 120
    /// 8 × 250ms = 2s.
    static let supportedGracePolls = 8

    static func step(
        status: AppleSpeechAssetStatus,
        didRequestInstall: Bool,
        consecutiveSupportedPolls: Int
    ) -> AppleSpeechAssetWaitStep {
        switch status {
        case .installed:
            return .installed
        case .downloading:
            return .keepWaiting
        case .supported:
            guard didRequestInstall else { return .giveUp }
            return consecutiveSupportedPolls <= supportedGracePolls ? .keepWaiting : .giveUp
        case .unsupported:
            return .giveUp
        }
    }
}

/// Injected at the inventory/install boundary so startup guarantees are executable without downloads.
enum AppleSpeechAssets {
    static func ensure(
        policy: AppleSpeechAssetPolicy,
        status: @escaping @Sendable () async -> AppleSpeechAssetStatus,
        install: @escaping @Sendable () async throws -> Bool,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onPreparing: @Sendable () async -> Void = {},
        inventoryTimeout: Duration? = nil,
        deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        try Task.checkCancellation()
        // Only installed-only startup and explicit foreground preparation opt into a deadline.
        // Existing install-capable public callers keep their original wait policy.
        let timeout = inventoryTimeout ?? (policy == .installedOnly ? AppleSpeechDependencyWait.inventoryTimeout : nil)
        let query: () async throws -> AppleSpeechAssetStatus = {
            guard let timeout else { return await status() }
            return try await AppleSpeechDependencyWait.run(timeout: timeout, sleep: deadlineSleep, operation: status)
        }
        let initial = try await query()
        try Task.checkCancellation()
        if initial == .installed { return }
        guard policy == .installIfNeeded, initial != .unsupported else {
            throw AppleLocalModelError.modelAssetsUnavailable
        }
        await onPreparing()
        try Task.checkCancellation()
        let didRequestInstall = try await install()
        var consecutiveSupportedPolls = 0
        for _ in 0 ..< AppleSpeechAssetWaitPolicy.maxPolls {
            try Task.checkCancellation()
            let current = try await query()
            try Task.checkCancellation()
            consecutiveSupportedPolls = current == .supported ? consecutiveSupportedPolls + 1 : 0
            switch AppleSpeechAssetWaitPolicy.step(
                status: current,
                didRequestInstall: didRequestInstall,
                consecutiveSupportedPolls: consecutiveSupportedPolls
            ) {
            case .installed: return
            case .keepWaiting: try await sleep(AppleSpeechAssetWaitPolicy.pollInterval)
            case .giveUp: throw AppleLocalModelError.modelAssetsUnavailable
            }
        }
        throw AppleLocalModelError.modelAssetsUnavailable
    }
}
