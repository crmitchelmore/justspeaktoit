import Foundation

/// The channel this build is distributed through.
///
/// macOS ships in two flavours from one codebase, selected at build time via the
/// `APP_STORE` Swift active compilation condition. That condition is defined by
/// `swift build -Xswiftc -DAPP_STORE` (SPM) or by `TUIST_APP_STORE=1 tuist generate`,
/// which wires it into the generated Xcode project (see `Project.swift`):
///
/// - `.direct`   — Developer ID / direct download. Unsandboxed, self-updates via
///                 Sparkle, and can install external local model runtimes.
/// - `.appStore` — Mac App Store. Sandboxed; no Sparkle or external executable
///                 runtime installers; some permissions must be granted manually.
///
/// Both channels can download model *data* consumed by an in-process, bundled
/// runtime (for example WhisperKit/Core ML). The sandbox restriction applies to
/// installing or spawning executable runtimes such as sherpa-onnx and llama.cpp.
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

    /// The channel the current app bundle was built for.
    ///
    /// Xcode does not propagate an app target's active compilation conditions into
    /// local Swift-package dependencies, so the generated macOS app records its
    /// channel in Info.plist. The compile-time branch remains useful for SwiftPM
    /// release/test builds that explicitly pass `-DAPP_STORE`.
    public static var current: DistributionChannel {
        #if os(iOS)
        // iOS only ever ships through the App Store / TestFlight.
        return .appStore
        #elseif APP_STORE
        return .appStore
        #else
        if let configuredChannel = Bundle.main.object(
            forInfoDictionaryKey: "SpeakDistributionChannel"
        ) as? String,
            configuredChannel == DistributionChannel.appStore.rawValue {
            return .appStore
        }
        return .direct
        #endif
    }

    /// Whether the current build runs inside the App Sandbox.
    /// App Store builds are always sandboxed; direct builds are not.
    public var isSandboxed: Bool { self == .appStore }
}

/// The only API-key persistence/sync presentation exposed by a build.
public enum APIKeyStorageMode: String, Sendable {
    /// Secrets remain solely in the local macOS Keychain.
    case localKeychainOnly
    /// Secrets are local by default and may be passphrase-encrypted into private CloudKit.
    case encryptedCloudKit
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
    /// Downloaded Core ML model data used by a runtime already bundled in the app.
    case downloadedCoreMLModels
    /// External runtimes (llama.cpp / sherpa-onnx) that install or spawn executable
    /// code and therefore cannot be offered in the App Store sandbox.
    case externalLocalModelRuntime
    /// Automatically prompting the user for Accessibility. Sandboxed builds cannot show the
    /// Accessibility prompt (`AXIsProcessTrustedWithOptions` is inert under the sandbox), so the
    /// user must add the app manually in System Settings. Input Monitoring is unaffected — it
    /// still prompts via `CGRequestListenEventAccess` even when sandboxed.
    case automaticAccessibilityPrompt
    /// Cross-app text insertion via AXUIElement. The App Store sandbox blocks
    /// reading and mutating another app's accessibility hierarchy.
    case accessibilityTextInsertion
    /// Freedom to reference other distribution channels or external purchases in UI copy.
    /// App Store review guidelines discourage this, so App Store builds must not.
    case crossChannelMessaging
    /// iCloud-backed sync features. Runtime entitlement/account probes still decide
    /// whether each iCloud service is actually available.
    case iCloudSync
    /// Passphrase-encrypted API-key sync through the user's private CloudKit database.
    case encryptedCloudKitKeySync
    /// Local-network Bonjour transport for cross-device fallback.
    case localNetworkTransport
}

public extension DistributionChannel {
    var apiKeyStorageMode: APIKeyStorageMode {
        self == .direct ? .localKeychainOnly : .encryptedCloudKit
    }

    /// Whether `feature` is available in this build.
    func supports(_ feature: ChannelFeature) -> Bool {
        switch feature {
        case .selfUpdate, .externalLocalModelRuntime, .automaticAccessibilityPrompt,
             .accessibilityTextInsertion, .crossChannelMessaging:
            return self == .direct
        case .iCloudSync, .encryptedCloudKitKeySync:
            // iOS and Mac App Store builds carry the managed iCloud entitlements.
            // Direct Mac keeps API keys solely in its local Keychain vault.
            return self == .appStore
        case .downloadedCoreMLModels, .localNetworkTransport:
            return true
        }
    }

    /// In-app self-update via Sparkle (direct builds only).
    var supportsSelfUpdate: Bool { supports(.selfUpdate) }

    /// Downloadable WhisperKit/Core ML model data (both channels).
    var supportsDownloadedCoreMLModels: Bool { supports(.downloadedCoreMLModels) }

    /// Installable executable local runtimes such as sherpa-onnx and llama.cpp (direct only).
    var supportsExternalLocalModelRuntime: Bool { supports(.externalLocalModelRuntime) }

    /// Whether the app can auto-prompt for Accessibility.
    /// When `false` (App Store), guide the user to add the app manually instead.
    var supportsAutomaticAccessibilityPrompt: Bool { supports(.automaticAccessibilityPrompt) }

    /// Whether this build may insert text directly into another app via AXUIElement.
    var supportsAccessibilityTextInsertion: Bool { supports(.accessibilityTextInsertion) }

    /// Whether UI copy may reference other distribution channels (e.g. the direct
    /// download). `false` for App Store builds to stay within review guidelines.
    var allowsCrossChannelMessaging: Bool { supports(.crossChannelMessaging) }

    /// Whether this distribution channel is expected to support iCloud sync when
    /// the running build also has the required entitlements and account state.
    var supportsICloudSync: Bool { supports(.iCloudSync) }

    /// Whether the encrypted CloudKit API-key sync feature should be initialized and shown.
    var supportsEncryptedCloudKitKeySync: Bool { supports(.encryptedCloudKitKeySync) }

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
