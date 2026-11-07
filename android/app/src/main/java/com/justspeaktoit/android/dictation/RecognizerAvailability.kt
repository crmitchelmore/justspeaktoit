package com.justspeaktoit.android.dictation

import java.util.Locale

/** What the device reports about speech recognition, gathered by [AndroidSpeechEngine]. */
data class RecognizerCapabilities(
    val sdkInt: Int,
    val speechServiceAvailable: Boolean,
    val onDeviceAvailable: Boolean,
)

/**
 * On-device model state for one language. [Unknown] is used before API 33, which cannot check;
 * [CheckFailed] means a check on API 33+ errored or timed out.
 */
enum class LanguageSupport { Installed, Downloadable, Downloading, Unsupported, Unknown, CheckFailed }

enum class ModeStatus {
    Ready,
    NeedsDownload,
    Downloading,
    LanguageUnsupported,
    RequiresNewerAndroid,
    NotProvided,
    NeedsKey,

    /** Usable if the user chooses it, but never picked by default: the language model is unconfirmed. */
    Unverified,
}

data class ModeAvailability(val mode: RecognitionMode, val status: ModeStatus) {
    val usable: Boolean get() = status == ModeStatus.Ready || status == ModeStatus.Unverified
}

object RecognizerAvailability {
    const val ON_DEVICE_MIN_SDK = 31
    const val SUPPORT_CHECK_MIN_SDK = 33

    fun evaluate(
        caps: RecognizerCapabilities,
        onDeviceLanguage: LanguageSupport,
        cloudKeySaved: Boolean = false,
    ): List<ModeAvailability> {
        val onDevice = when {
            caps.sdkInt < ON_DEVICE_MIN_SDK -> ModeStatus.RequiresNewerAndroid
            !caps.onDeviceAvailable -> ModeStatus.NotProvided
            else -> when (onDeviceLanguage) {
                LanguageSupport.Installed, LanguageSupport.Unknown -> ModeStatus.Ready
                LanguageSupport.Downloadable -> ModeStatus.NeedsDownload
                LanguageSupport.Downloading -> ModeStatus.Downloading
                LanguageSupport.Unsupported -> ModeStatus.LanguageUnsupported
                LanguageSupport.CheckFailed -> ModeStatus.Unverified
            }
        }
        val service = if (caps.speechServiceAvailable) ModeStatus.Ready else ModeStatus.NotProvided
        return listOf(
            ModeAvailability(RecognitionMode.OnDevice, onDevice),
            ModeAvailability(RecognitionMode.SpeechService, service),
            ModeAvailability(RecognitionMode.Cloud, if (cloudKeySaved) ModeStatus.Ready else ModeStatus.NeedsKey),
        )
    }

    /**
     * Prefers private, on-device recognition, then the device speech service. Cloud is never a
     * default: it is used only when the user chooses it. Returns null when nothing is usable.
     */
    fun defaultMode(options: List<ModeAvailability>): RecognitionMode? =
        options.firstOrNull { it.mode == RecognitionMode.OnDevice && it.status == ModeStatus.Ready }?.mode
            ?: options.firstOrNull { it.mode == RecognitionMode.SpeechService && it.usable }?.mode
            ?: options.firstOrNull { it.mode == RecognitionMode.OnDevice && it.usable }?.mode

    /**
     * Matches [languageTag] against the recogniser's lists and returns the tag to request. An exact
     * BCP 47 match wins; otherwise a language-only match (for example `en-US` for `en-GB`) is used,
     * so the recogniser is asked for a model it actually has.
     */
    fun resolveLanguage(
        languageTag: String,
        installed: List<String>,
        pending: List<String>,
        supported: List<String>,
    ): LanguageResolution {
        val lists = listOf(
            LanguageSupport.Installed to installed,
            LanguageSupport.Downloading to pending,
            LanguageSupport.Downloadable to supported,
        )
        for ((support, tags) in lists) {
            tags.firstOrNull { sameTag(it, languageTag) }?.let { return LanguageResolution(support, it) }
        }
        for ((support, tags) in lists) {
            tags.firstOrNull { sameLanguage(it, languageTag) }?.let { return LanguageResolution(support, it) }
        }
        return LanguageResolution(LanguageSupport.Unsupported, languageTag)
    }

    private fun sameTag(a: String, b: String): Boolean =
        Locale.forLanguageTag(a).toLanguageTag().equals(Locale.forLanguageTag(b).toLanguageTag(), ignoreCase = true)

    private fun sameLanguage(a: String, b: String): Boolean =
        Locale.forLanguageTag(a).language.equals(Locale.forLanguageTag(b).language, ignoreCase = true)
}

data class LanguageResolution(val support: LanguageSupport, val languageTag: String)
