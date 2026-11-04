package com.justspeaktoit.android.dictation

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudClient
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.WavFormat
import com.justspeaktoit.android.cloud.WavRecorder
import com.justspeaktoit.android.security.KeystoreSecretStore
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.AppPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

/** Optional OpenRouter cleanup of a final transcript. A failure keeps the original text. */
enum class CleanupStatus { None, Running, Applied, Failed }

data class DictationUiState(
    val dictation: DictationState = DictationState.Idle,
    val options: List<ModeAvailability> = emptyList(),
    /** The user's explicit choice; null means "use the best available on-device or device mode". */
    val chosenMode: RecognitionMode? = null,
    val languageTag: String = Locale.getDefault().toLanguageTag(),
    val onDeviceLanguageTag: String = languageTag,
    val checkingAvailability: Boolean = true,
    val cloudModel: CloudModel = CloudCatalog.defaultTranscriptionModel,
    val savedKeys: Set<CloudProvider> = emptySet(),
    val cleanupEnabled: Boolean = false,
    val cleanup: CleanupStatus = CleanupStatus.None,
    val originalTranscript: String? = null,
) {
    val activeMode: RecognitionMode?
        get() = chosenMode ?: RecognizerAvailability.defaultMode(options)

    val activeAvailability: ModeAvailability?
        get() = options.firstOrNull { it.mode == activeMode }

    val canStart: Boolean
        get() = !dictation.isActive && cleanup != CleanupStatus.Running && activeAvailability?.usable == true

    /** Cleanup runs only when switched on and an OpenRouter key exists. */
    val cleanupReady: Boolean
        get() = cleanupEnabled && CloudProvider.OpenRouter in savedKeys
}

class DictationViewModel(application: Application) : AndroidViewModel(application) {
    private val engine = AndroidSpeechEngine(application)
    private val secrets: SecretStore = KeystoreSecretStore.create(application)
    private val prefs = AppPreferences(application)
    private val cloud = CloudClient()
    private val cacheDir = application.cacheDir

    private val _state = MutableStateFlow(
        DictationUiState(
            chosenMode = prefs.chosenMode,
            cloudModel = CloudCatalog.transcriptionModel(prefs.cloudModelId),
            cleanupEnabled = prefs.cleanupEnabled,
        ),
    )
    val state: StateFlow<DictationUiState> = _state.asStateFlow()

    // Kept separate so microphone level updates only recompose the level indicator.
    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level.asStateFlow()

    private var recorder: WavRecorder? = null
    private var recording: File? = null
    private var work: Job? = null

    /** Called whenever the screen starts, so newly installed models, services or keys are noticed. */
    fun refreshAvailability() {
        if (_state.value.dictation.isActive) return
        // Presence only: names are listed without decrypting any secret.
        val names = secrets.names()
        val saved = CloudCatalog.providers.filterTo(mutableSetOf()) { it.credentialId in names }
        val caps = engine.capabilities()
        val tag = Locale.getDefault().toLanguageTag()
        _state.update { it.copy(languageTag = tag, savedKeys = saved, checkingAvailability = true) }
        engine.checkOnDeviceLanguage(tag) { resolution ->
            _state.update {
                it.copy(
                    options = RecognizerAvailability.evaluate(
                        caps,
                        resolution.support,
                        cloudKeySaved = it.cloudModel.provider in it.savedKeys,
                    ),
                    onDeviceLanguageTag = resolution.languageTag,
                    checkingAvailability = false,
                )
            }
        }
    }

    fun chooseMode(mode: RecognitionMode) {
        if (_state.value.dictation.isActive) return
        prefs.chosenMode = mode
        _state.update { it.copy(chosenMode = mode) }
    }

    fun chooseCloudModel(model: CloudModel) {
        prefs.cloudModelId = model.catalogId
        _state.update { it.copy(cloudModel = model) }
        refreshAvailability()
    }

    fun setCleanupEnabled(enabled: Boolean) {
        prefs.cleanupEnabled = enabled
        _state.update { it.copy(cleanupEnabled = enabled) }
    }

    fun saveKey(provider: CloudProvider, key: String) {
        secrets.write(provider.credentialId, key.trim())
        refreshAvailability()
    }

    fun removeKey(provider: CloudProvider) {
        secrets.remove(provider.credentialId)
        refreshAvailability()
    }

    fun downloadOnDeviceModel() {
        engine.requestOnDeviceModel(_state.value.onDeviceLanguageTag)
    }

    fun start() {
        val current = _state.value
        val mode = current.activeMode ?: return
        if (!current.canStart) return
        _state.update { it.copy(cleanup = CleanupStatus.None, originalTranscript = null) }
        dispatch(DictationEvent.Start(mode))
        when (mode) {
            RecognitionMode.Cloud -> startCloud()
            RecognitionMode.OnDevice ->
                engine.start(mode, current.onDeviceLanguageTag, onEvent = ::onEngineEvent, onLevel = ::setLevel)
            RecognitionMode.SpeechService ->
                engine.start(mode, current.languageTag, onEvent = ::onEngineEvent, onLevel = ::setLevel)
        }
    }

    fun stop() {
        val dictation = _state.value.dictation
        if (dictation !is DictationState.Starting && dictation !is DictationState.Listening) return
        dispatch(DictationEvent.StopRequested)
        if (dictation.modeOrNull() == RecognitionMode.Cloud) finishCloud() else engine.stop()
    }

    fun cancel() {
        engine.cancel()
        work?.cancel()
        discardRecording()
        _state.update {
            it.copy(cleanup = if (it.cleanup == CleanupStatus.Running) CleanupStatus.None else it.cleanup)
        }
        dispatch(DictationEvent.Cancelled)
    }

    /**
     * Android does not let a foreground-only app keep the microphone once it leaves the screen, so
     * capture ends as a failure. Work that no longer needs the microphone (an upload) continues.
     */
    fun onLeftApp() {
        val dictation = _state.value.dictation
        if (dictation !is DictationState.Starting && dictation !is DictationState.Listening) return
        engine.cancel()
        discardRecording()
        dispatch(DictationEvent.Error(DictationFailure.LeftApp))
    }

    fun clearResult() {
        if (_state.value.dictation.isActive || _state.value.cleanup == CleanupStatus.Running) return
        _state.update {
            it.copy(dictation = DictationState.Idle, cleanup = CleanupStatus.None, originalTranscript = null)
        }
    }

    fun showOriginal() {
        val original = _state.value.originalTranscript ?: return
        val done = _state.value.dictation as? DictationState.Done ?: return
        _state.update {
            it.copy(
                dictation = done.copy(transcript = original),
                cleanup = CleanupStatus.None,
                originalTranscript = null,
            )
        }
    }

    private fun startCloud() {
        val file = File(cacheDir, "dictation-${System.nanoTime()}.wav")
        val rec = WavRecorder(
            file = file,
            onLevel = { _level.value = it },
            onLimitReached = { viewModelScope.launch { stop() } },
        )
        if (!rec.start()) {
            file.delete()
            dispatch(DictationEvent.Error(DictationFailure.Audio))
            return
        }
        recorder = rec
        recording = file
        dispatch(DictationEvent.Ready)
    }

    private fun finishCloud() {
        val rec = recorder ?: return
        val file = recording ?: return
        recorder = null
        recording = null
        val model = _state.value.cloudModel
        val language = _state.value.languageTag
        work = viewModelScope.launch {
            val event = try {
                val bytes = withContext(Dispatchers.IO) { rec.stop() }
                when {
                    bytes < 0 -> DictationEvent.Error(DictationFailure.Audio)
                    bytes < MIN_AUDIO_BYTES -> DictationEvent.Error(DictationFailure.NoSpeech)
                    else -> {
                        val key = withContext(Dispatchers.IO) { secrets.read(model.provider.credentialId) }
                        if (key == null) {
                            DictationEvent.Error(DictationFailure.InvalidKey)
                        } else {
                            DictationEvent.Final(
                                withContext(Dispatchers.IO) { cloud.transcribe(model, key, file, language) },
                            )
                        }
                    }
                }
            } catch (e: CloudException) {
                DictationEvent.Error(e.failure)
            } finally {
                withContext(NonCancellable + Dispatchers.IO) { file.delete() }
            }
            onEngineEvent(event)
        }
    }

    private fun discardRecording() {
        val rec = recorder ?: return
        val file = recording
        recorder = null
        recording = null
        viewModelScope.launch(Dispatchers.IO) {
            rec.stop()
            file?.delete()
        }
    }

    private fun onEngineEvent(event: DictationEvent) {
        dispatch(event)
        val done = _state.value.dictation as? DictationState.Done ?: return
        if (event is DictationEvent.Final && _state.value.cleanupReady) runCleanup(done)
    }

    private fun runCleanup(done: DictationState.Done) {
        _state.update { it.copy(cleanup = CleanupStatus.Running) }
        work = viewModelScope.launch {
            val cleaned = try {
                val key = withContext(Dispatchers.IO) { secrets.read(CloudProvider.OpenRouter.credentialId) }
                key?.let { withContext(Dispatchers.IO) { cloud.cleanup(it, done.transcript) } }
            } catch (e: CloudException) {
                null
            }
            _state.update {
                if (it.dictation != done) {
                    it
                } else if (cleaned.isNullOrBlank()) {
                    it.copy(cleanup = CleanupStatus.Failed)
                } else {
                    it.copy(
                        dictation = done.copy(transcript = cleaned),
                        cleanup = CleanupStatus.Applied,
                        originalTranscript = done.transcript,
                    )
                }
            }
        }
    }

    private fun setLevel(value: Float) {
        _level.value = value
    }

    private fun dispatch(event: DictationEvent) {
        _state.update { it.copy(dictation = DictationReducer.reduce(it.dictation, event)) }
        if (!_state.value.dictation.isActive) _level.value = 0f
    }

    override fun onCleared() {
        engine.close()
        recorder?.stop()
        recording?.delete()
    }

    private companion object {
        /** About a quarter of a second; shorter recordings cannot contain a word. */
        const val MIN_AUDIO_BYTES = WavFormat.BYTES_PER_SECOND / 4
    }
}

private fun DictationState.modeOrNull(): RecognitionMode? = when (this) {
    is DictationState.Starting -> mode
    is DictationState.Listening -> mode
    is DictationState.Finishing -> mode
    is DictationState.Done -> mode
    is DictationState.Failed -> mode
    DictationState.Idle -> null
}
