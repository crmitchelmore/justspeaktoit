import SpeakCore

extension DesktopHostController {
    /// Native Preferences Apply refreshes metadata before rebuilding the cleanup picker.
    /// Imports only restore the flag; they never initiate a metadata request.
    func configureCleanupDiscovery(refresh: Bool) async {
        guard !closed else { return }
        let catalog = CleanupModelDiscoveryStore.shared
        catalog.setEnabled(settings.configuration?.enabled(CleanupModelSelection.preferenceKey) ?? false)
        guard refresh else { return }
        let state = await catalog.refresh()
        guard !closed, state.enabled else { return }
        updateProviderCredentialEditor(state.errorMessage
            ?? "Cleanup discovery updated. Open Post-processing to explicitly choose a model.")
    }
}
