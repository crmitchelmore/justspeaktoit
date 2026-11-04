package com.justspeaktoit.android.dictation

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.justspeaktoit.android.cloud.CallHandle
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
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File
import java.security.GeneralSecurityException
import java.security.ProviderException
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
    /** Set when a key could not be saved or removed securely. */
    val keyStoreError: Boolean = false,
) {
    /** The mode a new session would use. */
    val activeMode: RecognitionMode?
        get() = chosenMode ?: RecognizerAvailability.defaultMode(options)

    /** While a session runs, its own mode, so a refresh can never relabel its privacy. */
    val displayedMode: RecognitionMode?
        get() = when (dictation) {
            is DictationState.Starting -> dictation.mode
            is DictationState.Listening -> dictation.mode
            is DictationState.Finishing -> dictation.mode
            else -> activeMode
        }

    val activeAvailability: ModeAvailability?
        get() = options.firstOrNull { it.mode == displayedMode }

    /** Starting waits for a coherent availability result for the current language. */
    val canStart: Boolean
        get() = !dictation.isActive && !checkingAvailability && cleanup != CleanupStatus.Running &&
            options.firstOrNull { it.mode == activeMode }?.usable == true

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

    fun saveKey(provider: CloudProvider, key: String) =
        updateKeys { secrets.write(provider.credentialId, key.trim()) }

    fun removeKey(provider: CloudProvider) = updateKeys { secrets.remove(provider.credentialId) }

    private fun updateKeys(change: () -> Unit) {
        val ok = try {
            change()
            true
        } catch (e: GeneralSecurityException) {
            false
        } catch (e: ProviderException) {
            false
        }
        _state.update { it.copy(keyStoreError = !ok) }
        refreshAvailability()
    }

    private var downloadWatch: Job? = null

    /**
     * Requests the model, then rechecks support until it is installed or the wait ends, so Start
     * becomes available without leaving the app (the platform reports progress only via rechecks).
     */
    fun downloadOnDeviceModel() {
        engine.requestOnDeviceModel(_state.value.onDeviceLanguageTag)
        downloadWatch?.cancel()
        downloadWatch = viewModelScope.launch {
            repeat(DOWNLOAD_CHECKS) {
                delay(DOWNLOAD_CHECK_INTERVAL_MS)
                refreshAvailability()
                val status = _state.value.options.firstOrNull { it.mode == RecognitionMode.OnDevice }?.status
                if (status != ModeStatus.NeedsDownload && status != ModeStatus.Downloading) return@launch
            }
        }
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
        lateinit var rec: WavRecorder
        rec = WavRecorder(
            file = file,
            onLevel = { _level.value = it },
            onLimitReached = { viewModelScope.launch { if (recorder === rec) stop() } },
            onCaptureFailed = { viewModelScope.launch { if (recorder === rec) failCapture() } },
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

    private fun failCapture() {
        discardRecording()
        dispatch(DictationEvent.Error(DictationFailure.Audio))
    }

    private fun finishCloud() {
        val rec = recorder ?: return
        val file = recording ?: return
        val model = _state.value.cloudModel
        val language = _state.value.languageTag
        work = viewModelScope.launch {
            val event = try {
                // The recorder stays owned (and releasable by onCleared) until stop() has finished.
                val bytes = withContext(NonCancellable + Dispatchers.IO) { rec.stop() }
                releaseOwnership(rec)
                when {
                    bytes < 0 -> DictationEvent.Error(DictationFailure.Audio)
                    bytes < MIN_AUDIO_BYTES -> DictationEvent.Error(DictationFailure.NoSpeech)
                    else -> {
                        val key = withContext(Dispatchers.IO) { secrets.read(model.provider.credentialId) }
                        if (key == null) {
                            DictationEvent.Error(DictationFailure.InvalidKey)
                        } else {
                            DictationEvent.Final(
                                cloudCall(TRANSCRIBE_DEADLINE_MS) { call ->
                                    cloud.transcribe(model, key, file, language, call)
                                },
                            )
                        }
                    }
                }
            } catch (e: CloudException) {
                DictationEvent.Error(e.failure)
            } catch (e: GeneralSecurityException) {
                DictationEvent.Error(DictationFailure.KeyUnavailable)
            } catch (e: ProviderException) {
                DictationEvent.Error(DictationFailure.KeyUnavailable)
            } finally {
                releaseOwnership(rec)
                withContext(NonCancellable + Dispatchers.IO) { file.delete() }
            }
            // A cancelled upload must not deliver a late result into a newer session.
            ensureActive()
            onEngineEvent(event)
        }
    }

    /** Stops capture without a result. Ownership is kept until the recorder has really stopped. */
    private fun discardRecording() {
        val rec = recorder ?: return
        val file = recording
        viewModelScope.launch {
            withContext(NonCancellable + Dispatchers.IO) {
                rec.stop()
                file?.delete()
            }
            releaseOwnership(rec)
        }
    }

    private fun releaseOwnership(rec: WavRecorder) {
        if (recorder === rec) {
            recorder = null
            recording = null
        }
    }

    /**
     * Runs a blocking request with an overall [deadlineMs]. Cancelling the coroutine or reaching the
     * deadline disconnects the request, so no upload or response read outlives the session.
     */
    private suspend fun <T> cloudCall(deadlineMs: Long, block: (CallHandle) -> T): T {
        val call = CallHandle()
        return try {
            withTimeout(deadlineMs) {
                coroutineScope {
                    val watchdog = launch {
                        try {
                            awaitCancellation()
                        } finally {
                            call.cancel()
                        }
                    }
                    try {
                        withContext(Dispatchers.IO) { block(call) }
                    } finally {
                        watchdog.cancel()
                    }
                }
            }
        } catch (e: TimeoutCancellationException) {
            throw CloudException(DictationFailure.NetworkTimeout, "Request deadline reached", e)
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
                key?.let { cloudCall(CLEANUP_DEADLINE_MS) { call -> cloud.cleanup(it, done.transcript, call) } }
            } catch (e: CloudException) {
                null
            } catch (e: GeneralSecurityException) {
                null
            } catch (e: ProviderException) {
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
        const val TRANSCRIBE_DEADLINE_MS = 180_000L
        const val CLEANUP_DEADLINE_MS = 60_000L
        const val DOWNLOAD_CHECK_INTERVAL_MS = 5_000L
        const val DOWNLOAD_CHECKS = 60
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
