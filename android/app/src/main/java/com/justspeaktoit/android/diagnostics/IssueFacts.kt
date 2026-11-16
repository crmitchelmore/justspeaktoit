package com.justspeaktoit.android.diagnostics

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus

/** What a report may hold: catalogue IDs and enum values, nothing the user typed or said. */
data class IssueFacts(
    val context: IssueContext? = null,
    val recordedModels: List<ModelSelection> = emptyList(),
    val environment: IssueEnvironment = IssueEnvironment(),
    val failures: List<IssueFailure> = emptyList(),
) {
    companion object {
        private val catalogue: Set<String> by lazy { CloudCatalog.transcriptionModels.map { it.catalogId }.toSet() }

        /** A report about one History entry: its recorded mode, model and failure reason, never its text. */
        fun forHistory(
            entry: HistoryEntry,
            environment: IssueEnvironment,
            models: Set<String> = catalogue,
        ): IssueFacts {
            val model = ModelSelection.project(entry.model, models)
            val failure = DictationFailure.entries.firstOrNull { it.name == entry.failure }
            val failures = when {
                failure != null -> listOf(IssueFailure.of(failure))
                entry.status == HistoryStatus.Failed -> listOf(IssueFailure())
                else -> emptyList()
            }
            return IssueFacts(
                context = IssueContext(model, IssueContext.mode(entry.mode)),
                recordedModels = if (entry.model == null) emptyList() else listOf(model),
                environment = environment,
                failures = failures,
            )
        }

        /** A general report from Settings, which describes only the app and device. */
        fun forSettings(environment: IssueEnvironment): IssueFacts = IssueFacts(environment = environment)
    }
}

/** Exact catalogue membership. Any other ID is reported as custom or unknown, without the ID itself. */
class ModelSelection private constructor(val classification: String, val identifier: String?) {
    fun toJson(): Map<String, Any?> = mapOf("classification" to classification, "identifier" to identifier)

    override fun equals(other: Any?): Boolean =
        other is ModelSelection && other.classification == classification && other.identifier == identifier

    override fun hashCode(): Int = classification.hashCode() * 31 + identifier.hashCode()

    companion object {
        private const val MAX_ID_BYTES = 160
        val Unavailable = ModelSelection("unavailable", null)

        fun project(id: String?, catalogue: Set<String>): ModelSelection = when {
            id == null -> Unavailable
            id in catalogue && id.toByteArray(Charsets.UTF_8).size <= MAX_ID_BYTES -> ModelSelection("builtIn", id)
            else -> ModelSelection("customOrUnknown", null)
        }
    }
}

/** The configuration a History entry recorded when it ran; an admission, not proof a provider received it. */
data class IssueContext(val model: ModelSelection, val mode: String) {
    fun toJson(includeModels: Boolean): Map<String, Any?> = mapOf(
        "provenance" to "admission",
        "model" to (if (includeModels) model else ModelSelection.Unavailable).toJson(),
        "postProcessingModel" to ModelSelection.Unavailable.toJson(),
        "mode" to mode,
        "origin" to "unknown",
        "language" to emptyMap<String, Any?>(),
        "destination" to "unknown",
        // Android records no request options; the key stays so the shape matches the other platforms.
        "options" to emptyMap<String, Any?>(),
    )

    companion object {
        /** Cloud dictation uploads a finished recording; the recognisers stream partial results. */
        fun mode(recorded: String): String = when (RecognitionMode.entries.firstOrNull { it.name == recorded }) {
            RecognitionMode.Cloud -> "batch"
            RecognitionMode.OnDevice -> "local"
            RecognitionMode.SpeechService -> "live"
            null -> "unknown"
        }
    }
}

/**
 * The device and build, as numeric versions and enum values. `platform` is always `android`, an
 * extension of SpeakCore's platform values.
 */
data class IssueEnvironment(
    val architecture: String = "unknown",
    val channel: String = "unknown",
    val appVersion: String? = null,
    val appBuild: String? = null,
    val osVersion: String? = null,
    val microphonePermission: String = "unknown",
) {
    fun toJson(): Map<String, Any?> = mapOf(
        "platform" to "android",
        "architecture" to architecture,
        "channel" to channel,
        "appVersion" to numericVersion(appVersion),
        "appBuild" to numericVersion(appBuild),
        "osVersion" to numericVersion(osVersion),
        "microphonePermission" to microphonePermission,
    )

    companion object {
        private const val MAX_VERSION_LENGTH = 32
        private const val MAX_COMPONENT_LENGTH = 8
        private const val MAX_COMPONENTS = 4

        fun architecture(abi: String?): String = when (abi) {
            "arm64-v8a" -> "arm64"
            "x86_64" -> "x86_64"
            else -> "unknown"
        }

        /** Numeric release versions only, as SpeakCore allows: no build labels or vendor strings. */
        fun numericVersion(value: String?): String? {
            if (value.isNullOrEmpty() || value.length > MAX_VERSION_LENGTH) return null
            if (!value.all { it in '0'..'9' || it == '.' }) return null
            val parts = value.split('.')
            val valid = parts.size <= MAX_COMPONENTS && parts.all { it.isNotEmpty() && it.length <= MAX_COMPONENT_LENGTH }
            return value.takeIf { valid }
        }
    }
}

/** One failure observation: stage, code and domain, never the provider's message. */
data class IssueFailure(
    val stage: String = "unknown",
    val code: String = "unknown",
    val domain: String = "unknown",
    val httpStatus: Int? = null,
) {
    fun toJson(): Map<String, Any?> =
        mapOf("stage" to stage, "code" to code, "domain" to domain, "httpStatus" to httpStatus)

    companion object {
        private const val TOO_MANY_REQUESTS = 429

        fun of(failure: DictationFailure): IssueFailure = when (failure) {
            DictationFailure.NoSpeech, DictationFailure.NoMatch ->
                IssueFailure("finalization", "invalidInput", "provider")
            DictationFailure.Network -> IssueFailure("request", "transport", "transport")
            DictationFailure.NetworkTimeout -> IssueFailure("request", "timeout", "transport")
            DictationFailure.Audio, DictationFailure.RecognizerBusy ->
                IssueFailure("admission", "unavailable", "operatingSystem")
            DictationFailure.PermissionDenied -> IssueFailure("admission", "permission", "operatingSystem")
            DictationFailure.Server -> IssueFailure("request", "unavailable", "provider")
            DictationFailure.Client -> IssueFailure("request", "invalidInput", "application")
            DictationFailure.TooManyRequests -> IssueFailure("request", "unavailable", "provider", TOO_MANY_REQUESTS)
            DictationFailure.LanguageNotSupported, DictationFailure.LanguageUnavailable ->
                IssueFailure("admission", "unavailable", "provider")
            DictationFailure.LeftApp, DictationFailure.RecordingRecovered ->
                IssueFailure("unknown", "cancelled", "application")
            DictationFailure.InterruptedByCall, DictationFailure.AudioFocusLost, DictationFailure.AudioDeviceChanged ->
                IssueFailure("unknown", "cancelled", "operatingSystem")
            DictationFailure.Unavailable -> IssueFailure("admission", "unavailable", "unknown")
            DictationFailure.InvalidKey -> IssueFailure("request", "authentication", "provider")
            DictationFailure.KeyUnavailable, DictationFailure.MissingKey ->
                IssueFailure("admission", "authentication", "application")
            DictationFailure.AudioTooLarge, DictationFailure.UnsupportedAudio ->
                IssueFailure("request", "invalidInput", "provider")
            DictationFailure.Unknown -> IssueFailure()
        }
    }
}
