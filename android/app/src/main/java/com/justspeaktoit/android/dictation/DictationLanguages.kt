package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.GeneratedCloudCatalog
import java.util.Locale

/** A language the user can dictate in, from SpeakCore's `TranscriptionLanguageCatalog`. */
data class DictationLanguage(val id: String, val displayName: String) {
    val isAutomatic: Boolean get() = id == DictationLanguages.AUTOMATIC
}

/**
 * The shared language catalogue and how a saved choice becomes a recogniser language tag. Every
 * Android recogniser needs a concrete locale, so Automatic means the phone's language on every route.
 */
object DictationLanguages {
    const val AUTOMATIC = "automatic"

    val all: List<DictationLanguage> = GeneratedCloudCatalog.languages.map { DictationLanguage(it.id, it.displayName) }

    /** A saved identifier the catalogue knows; anything else (including null and "auto") is Automatic. */
    fun normalized(id: String?): String {
        val trimmed = id?.trim().orEmpty()
        return all.firstOrNull { it.id == trimmed }?.id ?: AUTOMATIC
    }

    fun language(id: String?): DictationLanguage = normalized(id).let { current -> all.first { it.id == current } }

    /** The BCP 47 tag a session uses: the chosen language, or the phone's for Automatic. */
    fun languageTag(id: String?, phoneLanguageTag: () -> String = { Locale.getDefault().toLanguageTag() }): String {
        val current = normalized(id)
        return if (current == AUTOMATIC) phoneLanguageTag() else current.replace('_', '-')
    }
}
