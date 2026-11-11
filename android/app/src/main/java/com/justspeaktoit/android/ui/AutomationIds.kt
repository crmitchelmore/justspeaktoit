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
    const val OPEN_HISTORY = "dictation.openHistory"
    const val OPEN_SETTINGS = "dictation.openSettings"
    const val HISTORY_BACK = "history.back"
    const val HISTORY_CLEAR = "history.clear"
    const val SETTINGS_BACK = "settings.back"
    const val SETTINGS_SEARCH = "settingsSearchField"
    const val SETTINGS_SEARCH_CLEAR = "settingsSearchClear"
    const val API_KEYS_FILTER = "settings.apiKeysFilter"
    const val SETTINGS_PRIVACY_POLICY = "settings.privacyPolicy"
    const val RESOURCES_HEADLINE = "settings.resources.headline"
    const val RESOURCES_RELEASE_EVERYTHING = "settings.resources.releaseEverything"

    /**
     * One per hold row, keyed by the shared kind and the owner, so the app's recording and the keyboard's
     * each get their own, e.g. `settings.resources.release.microphone.DictationViewModel`.
     */
    fun resourceRelease(kind: SystemResourceKind, owner: String): String =
        "settings.resources.release.${kind.rawValue}.$owner"
}
