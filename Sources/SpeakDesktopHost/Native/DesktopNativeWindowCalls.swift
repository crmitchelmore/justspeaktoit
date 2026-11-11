import Foundation

/// Native window calls whose C signatures are identical on Windows and Linux.
/// Each host fills these tables from its own C module (`CWindowsSupport` or
/// `CLinuxSupport`), so the presentation code that drives them lives once, in
/// `DesktopNativeWindowPlatform`. Strings are borrowed for each call only.
package struct DesktopNativeWindowCalls: Sendable {
    package typealias CString = UnsafePointer<CChar>?
    /// phase, headline, subheadline, live text, display milliseconds, compact, expanded.
    package typealias HUDLayout = @Sendable (Int32, CString, CString, CString, Int32, Int32, Int32) -> Int32

    package var beginCleanupPreview: @Sendable () -> UInt64
    package var cleanupPreview: @Sendable (CString, UInt64) -> Int32
    package var endCleanupPreview: @Sendable (UInt64) -> Void
    package var setHistoryManagement: @Sendable (CString) -> Int32
    package var setHUDLayout: HUDLayout

    package init(
        beginCleanupPreview: @escaping @Sendable () -> UInt64,
        cleanupPreview: @escaping @Sendable (CString, UInt64) -> Int32,
        endCleanupPreview: @escaping @Sendable (UInt64) -> Void,
        setHistoryManagement: @escaping @Sendable (CString) -> Int32,
        setHUDLayout: @escaping HUDLayout
    ) {
        self.beginCleanupPreview = beginCleanupPreview
        self.cleanupPreview = cleanupPreview
        self.endCleanupPreview = endCleanupPreview
        self.setHistoryManagement = setHistoryManagement
        self.setHUDLayout = setHUDLayout
    }
}

/// The comparison window's presentation calls.
package struct DesktopNativeComparisonCalls: Sendable {
    package typealias CString = UnsafePointer<CChar>?
    /// models, rounds, detail, selected, busy, recording, judgeable, sync enabled,
    /// sync available, references, reference, batch round, batch remaining, can advance.
    package typealias PresentBatch = @Sendable (
        CString, CString, CString, CString, Int32, Int32, Int32, Int32, Int32,
        CString, CString, CString, Int32, Int32
    ) -> Int32

    package var presentBatch: PresentBatch
    package var setSaveHistory: @Sendable (Int32) -> Int32

    package init(presentBatch: @escaping PresentBatch, setSaveHistory: @escaping @Sendable (Int32) -> Int32) {
        self.presentBatch = presentBatch
        self.setSaveHistory = setSaveHistory
    }
}

/// Voice Output's usage, text import, generated-result and preference calls.
package struct DesktopNativeVoiceCalls: Sendable {
    package typealias CString = UnsafePointer<CChar>?

    /// request ID, text, tracking enabled.
    package var setUsage: @Sendable (CString, CString, Int32) -> Int32
    /// request token, imported text, error.
    package var setTextImport: @Sendable (CString, CString, CString) -> Int32
    /// result ID, working, message, format.
    package var setGeneratedResult: @Sendable (CString, Int32, CString, CString) -> Int32
    /// `VoiceGenerationOptions.nativeFlags`.
    package var setGenerationOptions: @Sendable (Int32) -> Int32
    /// request ID, saved: completes a pending synthesis-controls Save.
    package var finishSynthesisOptions: @Sendable (CString, Int32) -> Int32

    package init(
        setUsage: @escaping @Sendable (CString, CString, Int32) -> Int32,
        setTextImport: @escaping @Sendable (CString, CString, CString) -> Int32,
        setGeneratedResult: @escaping @Sendable (CString, Int32, CString, CString) -> Int32,
        setGenerationOptions: @escaping @Sendable (Int32) -> Int32,
        finishSynthesisOptions: @escaping @Sendable (CString, Int32) -> Int32
    ) {
        self.setUsage = setUsage
        self.setTextImport = setTextImport
        self.setGeneratedResult = setGeneratedResult
        self.setGenerationOptions = setGenerationOptions
        self.finishSynthesisOptions = finishSynthesisOptions
    }
}

/// Voice provider accounts: the account voice listing, providers and key editors.
package struct DesktopNativeVoiceAccountCalls: Sendable {
    package typealias CString = UnsafePointer<CChar>?
    /// request ID, labels, identifiers, selected, status, loading.
    package typealias Inventory = @Sendable (CString, CString, CString, Int32, CString, Int32) -> Int32
    /// session, epoch, provider IDs, labels, selected.
    package typealias Providers = @Sendable (CString, CString, CString, CString, Int32) -> Int32

    package var setInventory: Inventory
    package var setProviders: Providers
    package var keys: DesktopNativeVoiceCredentialCalls

    package init(
        setInventory: @escaping Inventory, setProviders: @escaping Providers, keys: DesktopNativeVoiceCredentialCalls
    ) {
        self.setInventory = setInventory
        self.setProviders = setProviders
        self.keys = keys
    }
}

/// The Voice provider and account key editors' state and result calls.
package struct DesktopNativeVoiceCredentialCalls: Sendable {
    package typealias CString = UnsafePointer<CChar>?
    /// request ID, selection epoch, identifier, label, privacy, status, saved, can save.
    package typealias Credential = @Sendable (
        CString, CString, CString, CString, CString, CString, Int32, Int32
    ) -> Int32
    /// request ID, selection epoch, success, message.
    package typealias CredentialFinished = @Sendable (CString, CString, Int32, CString) -> Int32
    /// request ID, session, epoch, provider, identifier, label, privacy, status, saved, can save.
    package typealias ProviderCredential = @Sendable (
        CString, CString, CString, CString, CString, CString, CString, CString, Int32, Int32
    ) -> Int32
    /// request ID, session, epoch, provider, success, message.
    package typealias ProviderCredentialFinished = @Sendable (
        CString, CString, CString, CString, Int32, CString
    ) -> Int32

    package var setCredential: Credential
    package var finishCredential: CredentialFinished
    package var setProviderCredential: ProviderCredential
    package var finishProviderCredential: ProviderCredentialFinished

    package init(
        setCredential: @escaping Credential,
        finishCredential: @escaping CredentialFinished,
        setProviderCredential: @escaping ProviderCredential,
        finishProviderCredential: @escaping ProviderCredentialFinished
    ) {
        self.setCredential = setCredential
        self.finishCredential = finishCredential
        self.setProviderCredential = setProviderCredential
        self.finishProviderCredential = finishProviderCredential
    }
}
