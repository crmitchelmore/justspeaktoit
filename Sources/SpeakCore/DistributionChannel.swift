import Foundation

/// The channel this build is distributed through.
///
/// macOS ships in two flavours from one codebase, selected at build time via the
/// `APP_STORE` Swift active compilation condition (wired in `Project.swift`, set with
/// `APP_STORE=1 tuist generate`):
///
/// - `.direct`   — Developer ID / direct download. Unsandboxed, self-updates via
///                 Sparkle, can run downloaded local model runtimes.
/// - `.appStore` — Mac App Store. Sandboxed; no Sparkle; no downloaded local model
///                 runtimes; some permissions must be granted manually.
///
/// iOS is always distributed through the App Store / TestFlight, so it always reports
/// `.appStore` regardless of the flag.
///
/// This is the single, canonical place that answers "is feature X available in this
/// build?". Reuse `DistributionChannel.current` and the availability helpers below
/// rather than sprinkling `#if APP_STORE` through feature code — that keeps the policy
/// in one place and keeps call sites testable.
public enum DistributionChannel: String, Sendable, CaseIterable {
    /// Developer ID / direct download (macOS only).
    case direct
    /// App Store (macOS Mac App Store, or iOS App Store / TestFlight).
    case appStore

    /// The channel the current build was compiled for.
    public static var current: DistributionChannel {
        #if os(iOS)
        // iOS only ever ships through the App Store / TestFlight.
        return .appStore
        #elseif APP_STORE
        return .appStore
        #else
        return .direct
        #endif
    }

    /// Whether the current build runs inside the App Sandbox.
    /// App Store builds are always sandboxed; direct builds are not.
    public var isSandboxed: Bool { self == .appStore }
}

// MARK: - Feature availability

/// A build-time capability that may be unavailable on some distribution channels.
///
/// Feature code should branch on `DistributionChannel.current.supports(_:)` (or the
/// named convenience properties) instead of testing the raw channel, so the *reason*
/// a feature is gated stays explicit and greppable.
public enum ChannelFeature: String, Sendable, CaseIterable {
    /// In-app self-update (Sparkle). App Store builds update through the store instead.
    case selfUpdate
    /// Downloaded local model runtimes (Python venv + llama.cpp / sherpa-onnx) that
    /// spawn subprocesses and build/download executable code — impossible when sandboxed.
    case localModelRuntime
    /// Automatically prompting the user for Accessibility / Input Monitoring. Sandboxed
    /// builds cannot auto-prompt; the user must add the app manually in System Settings.
    case automaticAccessibilityPrompt
    /// Freedom to reference other distribution channels or external purchases in UI copy.
    /// App Store review guidelines discourage this, so App Store builds must not.
    case crossChannelMessaging
    /// iCloud-backed sync features. Runtime entitlement/account probes still decide
    /// whether each iCloud service is actually available.
    case iCloudSync
    /// Local-network Bonjour transport for cross-device fallback.
    case localNetworkTransport
}

public extension DistributionChannel {
    /// Whether `feature` is available in this build.
    func supports(_ feature: ChannelFeature) -> Bool {
        switch feature {
        case .selfUpdate, .localModelRuntime, .automaticAccessibilityPrompt, .crossChannelMessaging:
            return self == .direct
        case .iCloudSync, .localNetworkTransport:
            // Sync transports are compiled into every build; runtime entitlement,
            // account, and local-network permission probes decide actual availability.
            // (The macOS Developer ID build also ships CloudKit entitlements.)
            return true
        }
    }

    /// In-app self-update via Sparkle (direct builds only).
    var supportsSelfUpdate: Bool { supports(.selfUpdate) }

    /// Downloaded local model runtimes (direct builds only).
    var supportsLocalModelRuntime: Bool { supports(.localModelRuntime) }

    /// Whether the app can auto-prompt for Accessibility / Input Monitoring.
    /// When `false` (App Store), guide the user to add the app manually instead.
    var supportsAutomaticAccessibilityPrompt: Bool { supports(.automaticAccessibilityPrompt) }

    /// Whether UI copy may reference other distribution channels (e.g. the direct
    /// download). `false` for App Store builds to stay within review guidelines.
    var allowsCrossChannelMessaging: Bool { supports(.crossChannelMessaging) }

    /// Whether this distribution channel is expected to support iCloud sync when
    /// the running build also has the required entitlements and account state.
    var supportsICloudSync: Bool { supports(.iCloudSync) }

    /// Whether Bonjour local-network transport is part of this build.
    var supportsLocalNetworkTransport: Bool { supports(.localNetworkTransport) }

    /// A short, human-readable name for the channel, for diagnostics and about screens.
    var displayName: String {
        switch self {
        case .direct: return "Direct Download"
        case .appStore: return "App Store"
        }
    }
}
