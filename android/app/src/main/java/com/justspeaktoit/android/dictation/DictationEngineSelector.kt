package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.DictationPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale

/** How a new session recognises speech: by recording for a cloud model, or through the platform recogniser. */
internal sealed interface SessionPlan {
    val mode: RecognitionMode
    val languageTag: String

    data class Cloud(val model: CloudModel, override val languageTag: String) : SessionPlan {
        override val mode: RecognitionMode get() = RecognitionMode.Cloud
    }

    data class Recognizer(override val mode: RecognitionMode, override val languageTag: String) : SessionPlan
}

/** The user's recognition choices and which modes can start now. */
internal data class EngineSelection(
    /** The user's explicit choice; null means "use the best available on-device or device mode". */
    val chosenMode: RecognitionMode?,
    val cloudModel: CloudModel,
    val languageTag: String,
    /** The tag the on-device recogniser actually has, which may differ from [languageTag] by region. */
    val onDeviceLanguageTag: String,
    val savedKeys: Set<CloudProvider>,
    val options: List<ModeAvailability>,
    /** True while the on-device language check for [languageTag] is outstanding. */
    val checking: Boolean,
)

/**
 * Owns engine selection: the persisted mode and cloud model, the availability of each mode for the
 * current language, and the [SessionPlan] a new session follows. Nothing changes while
 * [sessionActive], so a refresh can never relabel a running session's privacy. Call from the main
 * thread of [scope]; every change is handed to [publish].
 */
internal class DictationEngineSelector(
    private val engine: SpeechEngine,
    private val secrets: SecretStore,
    private val prefs: DictationPreferences,
    private val scope: CoroutineScope,
    private val timings: DictationTimings,
    private val sessionActive: () -> Boolean,
    private val currentLanguageTag: () -> String = { Locale.getDefault().toLanguageTag() },
    private val publish: (EngineSelection) -> Unit,
) {
    var selection: EngineSelection = currentLanguageTag().let { tag ->
        EngineSelection(
            chosenMode = prefs.chosenMode,
            cloudModel = CloudCatalog.transcriptionModel(prefs.cloudModelId),
            languageTag = tag,
            onDeviceLanguageTag = tag,
            savedKeys = emptySet(),
            options = emptyList(),
            checking = true,
        )
    }
        private set

    private var downloadWatch: Job? = null

    /** Rechecks keys, recognisers and the on-device language, so new models, services or keys are noticed. */
    fun refresh() {
        if (sessionActive()) return
        // Presence only: names are listed without decrypting any secret.
        val names = secrets.names()
        val saved = CloudCatalog.providers.filterTo(mutableSetOf()) { it.credentialId in names }
        val caps = engine.capabilities()
        val tag = currentLanguageTag()
        change { it.copy(languageTag = tag, savedKeys = saved, checking = true) }
        engine.checkOnDeviceLanguage(tag) { resolution ->
            change {
                it.copy(
                    options = RecognizerAvailability.evaluate(
                        caps,
                        resolution.support,
                        cloudKeySaved = it.cloudModel.provider in it.savedKeys,
                    ),
                    onDeviceLanguageTag = resolution.languageTag,
                    checking = false,
                )
            }
        }
    }

    fun chooseMode(mode: RecognitionMode) {
        if (sessionActive()) return
        prefs.chosenMode = mode
        change { it.copy(chosenMode = mode) }
    }

    /** A running session keeps the model it started with; the new one is used from the next session. */
    fun chooseCloudModel(model: CloudModel) {
        prefs.cloudModelId = model.catalogId
        change { it.copy(cloudModel = model) }
        refresh()
    }

    /**
     * Requests the on-device model, then rechecks support until it is installed or the wait ends, so
     * Start becomes available without leaving the app (the platform reports progress only via rechecks).
     */
    fun downloadOnDeviceModel() {
        engine.requestOnDeviceModel(selection.onDeviceLanguageTag)
        downloadWatch?.cancel()
        downloadWatch = scope.launch {
            repeat(timings.downloadChecks) {
                delay(timings.downloadCheckIntervalMs)
                refresh()
                val status = selection.options.firstOrNull { it.mode == RecognitionMode.OnDevice }?.status
                if (status != ModeStatus.NeedsDownload && status != ModeStatus.Downloading) return@launch
            }
        }
    }

    /** The route for a session in [mode], with the language its recogniser was resolved for. */
    fun plan(mode: RecognitionMode): SessionPlan = when (mode) {
        RecognitionMode.Cloud -> SessionPlan.Cloud(selection.cloudModel, selection.languageTag)
        RecognitionMode.OnDevice -> SessionPlan.Recognizer(mode, selection.onDeviceLanguageTag)
        RecognitionMode.SpeechService -> SessionPlan.Recognizer(mode, selection.languageTag)
    }

    private fun change(transform: (EngineSelection) -> EngineSelection) {
        selection = transform(selection)
        publish(selection)
    }
}
