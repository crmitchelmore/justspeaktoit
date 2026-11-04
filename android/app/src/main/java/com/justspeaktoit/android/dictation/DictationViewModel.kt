package com.justspeaktoit.android.dictation

import android.app.Application
import android.content.ContentResolver
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.justspeaktoit.android.cloud.CallHandle
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudClient
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.SharedAudio
import com.justspeaktoit.android.cloud.WavFormat
import com.justspeaktoit.android.cloud.WavRecorder
import com.justspeaktoit.android.history.AtomicHistoryFile
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.security.KeystoreSecretStore
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.AppPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
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
import java.io.IOException
import java.util.UUID
import java.security.GeneralSecurityException
import java.security.ProviderException
import java.util.Locale

data class SharedAudioOffer(val uri: Uri, val mimeType: String?)

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
    /** True until a discarded recording has released the microphone. */
    val releasingMicrophone: Boolean = false,
    /** Newest first. */
    val history: List<HistoryEntry> = emptyList(),
    val retention: Retention = Retention.Month,
    /** The last history change could not be written; it is retried with the next change. */
    val historyError: Boolean = false,
    /** Audio another app shared, waiting for the user to confirm the upload. */
    val sharedAudio: SharedAudioOffer? = null,
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
        get() = !dictation.isActive && !checkingAvailability && !releasingMicrophone &&
            cleanup != CleanupStatus.Running && options.firstOrNull { it.mode == activeMode }?.usable == true

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
    private val history = HistoryStore(AtomicHistoryFile(File(application.filesDir, "history.json")))

    // One thread owns the history file, so writes are ordered without locks.
    @OptIn(ExperimentalCoroutinesApi::class)
    private val historyDispatcher = Dispatchers.IO.limitedParallelism(1)

    private val _state = MutableStateFlow(
        DictationUiState(
            chosenMode = prefs.chosenMode,
            cloudModel = CloudCatalog.transcriptionModel(prefs.cloudModelId),
            cleanupEnabled = prefs.cleanupEnabled,
            retention = prefs.retention,
        ),
    )

    init {
        val retention = prefs.retention
        updateHistory { history.load(retention) }
    }
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
            maybeAutoStart()
        }
    }

    private var autoStartPending = false

    /**
     * Starts dictation as soon as availability is known, for the Quick Settings tile, shortcut and
     * permission grant. If the chosen mode is unusable nothing starts and its reason stays visible.
     */
    fun requestAutoStart() {
        if (_state.value.dictation.isActive) return
        autoStartPending = true
        maybeAutoStart()
    }

    private fun maybeAutoStart() {
        if (!autoStartPending || _state.value.checkingAvailability) return
        autoStartPending = false
        start()
    }

    /**
     * Audio shared by another app is only uploaded after the user confirms, so no app can spend
     * the user's cloud credit by sending audio here.
     */
    fun offerSharedAudio(uri: Uri, mimeType: String?) {
        if (_state.value.dictation.isActive) return
        _state.update { it.copy(sharedAudio = SharedAudioOffer(uri, mimeType)) }
    }

    fun dismissSharedAudio() {
        _state.update { it.copy(sharedAudio = null) }
    }

    fun confirmSharedAudio() {
        val offer = _state.value.sharedAudio ?: return
        _state.update { it.copy(sharedAudio = null) }
        transcribeSharedAudio(offer.uri, offer.mimeType)
    }

    private fun transcribeSharedAudio(uri: Uri, mimeType: String?) {
        val current = _state.value
        if (current.dictation.isActive || current.cleanup == CleanupStatus.Running) return
        val model = current.cloudModel
        val language = current.languageTag
        val resolver = getApplication<Application>().contentResolver
        _state.update { it.copy(cleanup = CleanupStatus.None, originalTranscript = null) }
        sessionModelId = model.catalogId
        dispatch(DictationEvent.Start(RecognitionMode.Cloud))
        dispatch(DictationEvent.StopRequested)
        work = viewModelScope.launch {
            val file = File(cacheDir, "shared-${System.nanoTime()}")
            val event = try {
                val format = SharedAudio.format(mimeType ?: resolver.getType(uri))
                    ?: throw CloudException(DictationFailure.UnsupportedAudio, "Unsupported audio")
                val key = withContext(Dispatchers.IO) { secrets.read(model.provider.credentialId) }
                    ?: throw CloudException(DictationFailure.MissingKey, "No key")
                withContext(Dispatchers.IO) { copyLimited(resolver, uri, file) }
                DictationEvent.Final(
                    cloudCall(TRANSCRIBE_DEADLINE_MS) { call ->
                        cloud.transcribe(model, key, file, language, call, format)
                    },
                )
            } catch (e: CloudException) {
                DictationEvent.Error(e.failure)
            } catch (e: GeneralSecurityException) {
                DictationEvent.Error(DictationFailure.KeyUnavailable)
            } catch (e: ProviderException) {
                DictationEvent.Error(DictationFailure.KeyUnavailable)
            } catch (e: IOException) {
                DictationEvent.Error(DictationFailure.Audio)
            } catch (e: SecurityException) {
                DictationEvent.Error(DictationFailure.Audio)
            } finally {
                withContext(NonCancellable + Dispatchers.IO) { file.delete() }
            }
            ensureActive()
            onEngineEvent(event)
        }
    }

    /** Copies at most [SharedAudio.MAX_BYTES], failing early rather than uploading a file a provider rejects. */
    private fun copyLimited(resolver: ContentResolver, uri: Uri, target: File) {
        val input = resolver.openInputStream(uri) ?: throw IOException("Unreadable audio")
        input.use { source ->
            target.outputStream().use { out ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = source.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > SharedAudio.MAX_BYTES) {
                        throw CloudException(DictationFailure.AudioTooLarge, "Audio too large")
                    }
                    out.write(buffer, 0, read)
                }
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
        sessionModelId = if (mode == RecognitionMode.Cloud) current.cloudModel.catalogId else null
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

    fun setRetention(retention: Retention) {
        prefs.retention = retention
        _state.update { it.copy(retention = retention) }
        updateHistory { history.load(retention) }
    }

    fun deleteHistoryEntry(id: String) {
        val retention = _state.value.retention
        updateHistory { history.remove(id, retention) }
    }

    fun clearHistory() = updateHistory { history.clear() }

    /** Re-reads and prunes history so the retention cutoff holds while the app stays open. */
    fun refreshHistory() {
        val retention = _state.value.retention
        updateHistory { history.load(retention) }
    }

    private fun updateHistory(change: () -> List<HistoryEntry>) {
        viewModelScope.launch {
            val (entries, failed) = withContext(historyDispatcher) {
                try {
                    change() to false
                } catch (e: IOException) {
                    history.cached to true
                }
            }
            _state.update { it.copy(history = entries, historyError = failed) }
        }
    }

    /** The latest session's history entry, so a later cleanup updates it rather than adding another. */
    private var lastEntry: HistoryEntry? = null

    // The model is fixed when the session starts, so later Settings changes cannot relabel it.
    private var sessionModelId: String? = null

    private fun record(state: DictationState) {
        val entry = when (state) {
            is DictationState.Done -> entry(state.mode, HistoryStatus.Completed, state.transcript, null)
            is DictationState.Failed -> entry(state.mode, HistoryStatus.Failed, state.unfinishedText, state.failure)
            else -> return
        }
        lastEntry = entry
        val retention = _state.value.retention
        updateHistory { history.add(entry, retention) }
    }

    private fun recordCleanup(cleaned: String) {
        val entry = lastEntry?.copy(text = cleaned, cleanedUp = true) ?: return
        lastEntry = entry
        val retention = _state.value.retention
        updateHistory { history.replace(entry, retention) }
    }

    private fun entry(mode: RecognitionMode, status: HistoryStatus, text: String, failure: DictationFailure?) =
        HistoryEntry(
            id = UUID.randomUUID().toString(),
            createdAtMs = System.currentTimeMillis(),
            mode = mode.name,
            model = if (mode == RecognitionMode.Cloud) sessionModelId else null,
            status = status,
            text = text,
            failure = failure?.name,
        )

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
        lastEntry?.copy(text = original, cleanedUp = false)?.let { entry ->
            lastEntry = entry
            val retention = _state.value.retention
            updateHistory { history.replace(entry, retention) }
        }
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
        _state.update { it.copy(releasingMicrophone = true) }
        viewModelScope.launch {
            withContext(NonCancellable + Dispatchers.IO) {
                rec.stop()
                file?.delete()
            }
            releaseOwnership(rec)
            _state.update { it.copy(releasingMicrophone = false) }
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
            if (_state.value.dictation != done) return@launch
            _state.update {
                if (cleaned.isNullOrBlank()) {
                    it.copy(cleanup = CleanupStatus.Failed)
                } else {
                    it.copy(
                        dictation = done.copy(transcript = cleaned),
                        cleanup = CleanupStatus.Applied,
                        originalTranscript = done.transcript,
                    )
                }
            }
            if (!cleaned.isNullOrBlank()) recordCleanup(cleaned)
        }
    }

    private fun setLevel(value: Float) {
        _level.value = value
    }

    private fun dispatch(event: DictationEvent) {
        val before = _state.value.dictation
        _state.update { it.copy(dictation = DictationReducer.reduce(it.dictation, event)) }
        val after = _state.value.dictation
        if (!after.isActive) _level.value = 0f
        if (!before.isActive || after.isActive) return
        // A session just ended: record it now, so it survives even if optional cleanup never finishes.
        record(after)
    }

    override fun onCleared() {
        engine.close()
        val rec = recorder ?: return
        val file = recording
        // Stop before delete, off the main thread: joining the capture thread here could cause an ANR.
        Thread({
            rec.stop()
            file?.delete()
        }, "jsti-recorder-teardown").start()
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
