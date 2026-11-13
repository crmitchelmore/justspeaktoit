package com.justspeaktoit.android.ui

import com.justspeaktoit.android.resources.SystemResourceKind

/**
 * Stable test tags for controls that screen readers and automation agents drive.
 * MainActivity exposes them as resource IDs, so UiAutomator and accessibility
 * services can find them by `resource-id`. Never reuse or rename a published ID.
 */
object AutomationIds {
    const val RECORD = "dictation.record"
    const val CANCEL = "dictation.cancel"
    const val STATUS = "dictation.status"
    const val TRANSCRIPT = "dictation.transcript"
    const val COPY = "dictation.copy"
    const val SHARE = "dictation.share"
    const val CLEAR = "dictation.clear"
    const val SHOW_ORIGINAL = "dictation.showOriginal"
    const val READ_ALOUD = "dictation.readAloud"
    const val OPEN_HISTORY = "dictation.openHistory"
    const val OPEN_SETTINGS = "dictation.openSettings"
    const val HISTORY_BACK = "history.back"
    const val HISTORY_CLEAR = "history.clear"
    const val HISTORY_INSIGHTS = "history.insights"
    const val HISTORY_CLEAR_ALL = "history.clear.all"
    const val HISTORY_CLEAR_KEEP_RECORDINGS = "history.clear.keepRecordings"

    /** One per History entry, keyed by its generated ID, never by its text. */
    fun historyPlay(entryId: String) = "history.play.$entryId"
    const val SETTINGS_BACK = "settings.back"
    const val SETTINGS_SEARCH = "settingsSearchField"
    const val SETTINGS_SEARCH_CLEAR = "settingsSearchClear"
    const val API_KEYS_FILTER = "settings.apiKeysFilter"
    const val SETTINGS_PRIVACY_POLICY = "settings.privacyPolicy"
    const val SETTINGS_ANALYTICS = "settings.analytics"
    const val SETTINGS_DIAGNOSTICS = "settings.diagnostics"
    const val TIP_JAR_STATUS = "settings.tipJar.status"
    const val CONSENT_ANALYTICS = "consent.analytics"
    const val CONSENT_DIAGNOSTICS = "consent.diagnostics"
    const val CONSENT_DONE = "consent.done"

    /** One per tip, keyed by its store product ID, e.g. `settings.tip.com.justspeaktoit.tip.small`. */
    fun tipProduct(productId: String) = "settings.tip.$productId"
    const val SETTINGS_REPORT_ISSUE = "settings.reportIssue"
    const val HISTORY_REPORT_ISSUE = "history.reportIssue"
    const val ISSUE_REPORT = "issueReport"
    const val ISSUE_REPORT_INCLUDE = "issueReport.includeDiagnostics"
    const val ISSUE_REPORT_DRAFT = "issueReport.draft"
    const val ISSUE_REPORT_COPY = "issueReport.copy"
    const val ISSUE_REPORT_OPEN = "issueReport.open"
    const val ISSUE_REPORT_CLOSE = "issueReport.close"
    const val SETTINGS_SILENCE = "settings.silenceDetection"
    const val SETTINGS_SILENCE_DURATION = "settings.silenceDuration"
    const val SETTINGS_SILENCE_THRESHOLD = "settings.silenceThreshold"

    const val SETTINGS_RUN_SETUP = "settings.runSetup"
    const val ONBOARDING_PROGRESS = "onboarding.progress"
    const val ONBOARDING_NEXT = "onboarding.next"
    const val ONBOARDING_BACK = "onboarding.back"
    const val ONBOARDING_SKIP = "onboarding.skip"
    const val ONBOARDING_ALLOW_MIC = "onboarding.allowMicrophone"
    const val ONBOARDING_OPEN_APP_SETTINGS = "onboarding.openAppSettings"
    const val ONBOARDING_KEYBOARD_SETTINGS = "onboarding.keyboardSettings"
    const val ONBOARDING_ADD_TILE = "onboarding.addTile"

    const val SETTINGS_KEEP_RECORDINGS = "settings.keepRecordings"
    const val RESOURCES_HEADLINE = "settings.resources.headline"
    const val RESOURCES_RELEASE_EVERYTHING = "settings.resources.releaseEverything"

    /**
     * One per hold row, keyed by the shared kind and the owner, so the app's recording and the keyboard's
     * each get their own, e.g. `settings.resources.release.microphone.DictationViewModel`.
     */
    fun resourceRelease(kind: SystemResourceKind, owner: String): String =
        "settings.resources.release.${kind.rawValue}.$owner"

    /** Shared with the Apple raw configuration editors. */
    const val RAW_CONFIG_EDITOR = "rawConfigurationEditor"
    const val RAW_CONFIG_LOAD = "rawConfigurationLoad"
    const val RAW_CONFIG_VALIDATE = "rawConfigurationValidate"
    const val RAW_CONFIG_APPLY = "rawConfigurationApply"
    const val RAW_CONFIG_IMPORT = "rawConfigurationImport"
    const val RAW_CONFIG_EXPORT = "rawConfigurationExport"
    const val RAW_CONFIG_RESET = "rawConfigurationReset"
    const val RAW_CONFIG_RESET_CONFIRM = "rawConfigurationResetConfirm"
    const val RAW_CONFIG_STATUS = "rawConfigurationStatus"

    const val SETTINGS_CLEANUP_MODEL = "settings.cleanupModel"
    const val SETTINGS_CLEANUP_PROMPT = "settings.cleanupPrompt"
    const val SETTINGS_CLEANUP_PROMPT_RESET = "settings.cleanupPrompt.reset"
    const val SETTINGS_PROFILE_ADD = "settings.profiles.add"
    const val PROFILE_CHOOSER = "dictation.profile"
    const val PROFILE_CHOOSER_NONE = "dictation.profile.none"
    const val PROFILE_EDITOR_NAME = "profileEditor.name"
    const val PROFILE_EDITOR_CLOUD_MODEL = "profileEditor.cloudModel"
    const val PROFILE_EDITOR_LANGUAGE = "profileEditor.language"
    const val PROFILE_EDITOR_CLEANUP = "profileEditor.cleanup"
    const val PROFILE_EDITOR_CLEANUP_MODEL = "profileEditor.cleanupModel"
    const val PROFILE_EDITOR_CLEANUP_MODEL_RESET = "profileEditor.cleanupModel.reset"
    const val PROFILE_EDITOR_PROMPT = "profileEditor.prompt"
    const val PROFILE_EDITOR_DELETE = "profileEditor.delete"
    const val PROFILE_EDITOR_SAVE = "profileEditor.save"

    /** One per profile, keyed by its position in the list, never by the user's own name for it. */
    fun profileOption(index: Int) = "dictation.profile.option.$index"

    /** One per profile row in Settings, keyed by its position. */
    fun profileEdit(index: Int) = "settings.profiles.edit.$index"
    const val SETTINGS_SOUNDS_ENABLED = "settings.recordingSounds.enabled"
    const val SETTINGS_SOUNDS_VOLUME = "settings.recordingSounds.volume"
    const val SETTINGS_SOUNDS_PREVIEW = "settings.recordingSounds.preview"

    /** One per sound profile, keyed by its shared ID (for example `classic`). */
    fun soundProfile(id: String) = "settings.recordingSounds.profile.$id"
    const val SETTINGS_LANGUAGE = "settings.language"
    const val SETTINGS_DYNAMIC_COLOR = "settings.appearance.dynamicColor"

    /** One per appearance choice, keyed by its cross-platform raw value (`system`, `light`, `dark`). */
    fun appearanceOption(rawValue: String) = "settings.appearance.$rawValue"
    const val CORRECTIONS_WRITE_AS = "settings.corrections.writeAs"
    const val CORRECTIONS_HEARD_AS = "settings.corrections.heardAs"
    const val CORRECTIONS_ADD = "settings.corrections.add"

    /** One per language in the picker, keyed by its catalogue ID (for example `en_GB`). */
    fun languageOption(id: String) = "languagePicker.language.$id"

    /** One per correction, keyed by its position in the list, never by the user's own text. */
    fun correctionRemove(index: Int) = "settings.corrections.remove.$index"
    const val LEARNED_CORRECTIONS_TOGGLE = "settings.learnedCorrections.toggle"
    const val LEARNED_CORRECTIONS_FEWER = "settings.learnedCorrections.fewer"
    const val LEARNED_CORRECTIONS_MORE = "settings.learnedCorrections.more"
    const val LEARNED_CORRECTIONS_CLEAR = "settings.learnedCorrections.clear"

    /** One per learned suggestion, keyed by its position in the list, never by the user's own text. */
    fun learnedCorrectionAccept(index: Int) = "settings.learnedCorrections.accept.$index"
    fun learnedCorrectionDismiss(index: Int) = "settings.learnedCorrections.dismiss.$index"
    const val CLEANUP_PICKER_BACK = "cleanupPicker.back"
    const val CLEANUP_PICKER_SEARCH = "cleanupPicker.search"
    const val CLEANUP_PICKER_OPENROUTER = "cleanupPicker.openRouter"

    /** One per cleanup model, keyed by its stable selection ID (for example `native/openai/gpt-6-luna`). */
    fun cleanupPickerModel(selectionId: String) = "cleanupPicker.model.$selectionId"
}
