#if canImport(CWindowsSupport)
import CWindowsSupport
#else
import CLinuxSupport
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// Binds the window functions and row types that `CWindowsSupport` and
/// `CLinuxSupport` declare with identical C signatures to the shared
/// presentation code in `SpeakDesktopHost`. The Windows and Linux builds each
/// compile this one file against their own C module, so a signature that
/// drifts on one side fails that build instead of forking the Swift code.
package enum DesktopNativeBindings {
    package static let window = DesktopNativeWindowCalls(
        beginCleanupPreview: jsti_window_begin_cleanup_preview,
        cleanupPreview: jsti_window_cleanup_preview,
        endCleanupPreview: jsti_window_end_cleanup_preview,
        setHistoryManagement: jsti_window_set_history_management,
        setHUDLayout: jsti_window_set_hud_layout,
        setRawConfiguration: jsti_window_set_raw_configuration
    )

    package static let comparison = DesktopNativeComparisonCalls(
        presentBatch: jsti_comparison_present_batch, setSaveHistory: jsti_comparison_set_save_history
    )

    package static let voice = DesktopNativeVoiceCalls(
        setUsage: jsti_window_set_voice_usage,
        setTextImport: jsti_window_set_voice_text_import,
        setGeneratedResult: jsti_window_set_voice_generated_result_with_format,
        setGenerationOptions: jsti_window_set_voice_generation_options,
        finishSynthesisOptions: jsti_window_finish_voice_synthesis_options
    )

    package static let voiceAccounts = DesktopNativeVoiceAccountCalls(
        setInventory: jsti_window_set_voice_account_inventory,
        setProviders: jsti_window_set_voice_account_providers,
        keys: DesktopNativeVoiceCredentialCalls(
            setCredential: jsti_window_set_voice_credential,
            finishCredential: jsti_window_finish_voice_credential,
            setProviderCredential: jsti_window_set_voice_provider_credential,
            finishProviderCredential: jsti_window_finish_voice_provider_credential
        )
    )

    package static let configuration = DesktopNativeConfigurationCalls<JSTIConfigurationField>(
        makeField: {
            JSTIConfigurationField(
                title: $0.title, value: $0.value, group: $0.group, is_boolean: $0.isBoolean,
                requires_hud_overlay: $0.requiresHUDOverlay, choices: $0.choices,
                requires_hands_free_guard: $0.requiresHandsFreeGuard, enabled_by_field: $0.enabledByField
            )
        },
        setRevision: jsti_window_set_configuration_revision,
        setFieldTitle: jsti_window_set_configuration_field_title,
        setFieldEnabled: jsti_window_set_configuration_field_enabled,
        setEscapeCancellation: jsti_window_set_escape_cancellation
    )

    package static let layout = DesktopNativeLayoutCalls<JSTIVisualDensity, JSTISidebarShortcut>(
        makeDensity: { density in
            JSTIVisualDensity(
                compact: density.isCompact ? 1 : 0,
                page_padding: Int32(density.pagePadding), section_spacing: Int32(density.sectionSpacing),
                card_padding: Int32(density.cardPadding), content_spacing: Int32(density.cardContentSpacing),
                inline_spacing: Int32(density.inlineSpacing), group_spacing: Int32(density.groupSpacing),
                minimum_row_height: Int32(density.minimumListRowHeight)
            )
        },
        setDensity: jsti_window_set_visual_density,
        makeShortcut: { JSTISidebarShortcut(destination: $0, digit: $1, hint: $2) },
        setSidebarShortcuts: jsti_window_set_sidebar_shortcuts
    )

    package static func configureAbout(for platform: DesktopAboutInformation.Platform) throws {
        try DesktopNativeLists.configureAbout(
            for: platform, link: { JSTIAboutLink(title: $0, url: $1) }, configure: jsti_window_configure_about
        )
    }

    /// False when the window refused the filter controls.
    package static func historyFilters(models: [String], selection: DesktopHistoryFilter) -> Bool {
        DesktopNativeLists.historyFilters(
            models: models, selection: selection, model: { JSTIHistoryFilterModel(id: $0, name: $1, selected: $2) },
            set: jsti_window_set_history_filters
        )
    }

    /// False when the window refused the results.
    package static func settingsSearchResults(_ rows: [DesktopSettingsSearchSession.Row]) -> Bool {
        DesktopNativeLists.settingsSearchResults(
            rows, row: { JSTISettingsSearchResult(title: $0, detail: $1, identifier: $2) },
            set: jsti_window_set_settings_search_results
        )
    }

    /// False when the window refused the SSML helper's examples.
    package static func voiceMarkupHelper(enabled: Bool) -> Bool {
        DesktopNativeLists.voiceMarkupHelper(
            enabled: enabled, example: { JSTIVoiceMarkupExample(text: $0, description: $1) },
            set: jsti_window_set_voice_markup_helper
        )
    }
}
