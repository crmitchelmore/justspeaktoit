package com.justspeaktoit.android.dictation

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudClient
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.RecorderFactory
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.cloud.WavFormat
import com.justspeaktoit.android.cloud.WavRecorder
import com.justspeaktoit.android.history.AtomicHistoryFile
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceHold
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.resources.SystemResourceToken
import com.justspeaktoit.android.security.KeystoreSecretStore
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.settings.DictationPreferences
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
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
    val cleanupModel: CleanupModel = CloudCatalog.cleanupModel(null),
    val cleanup: CleanupStatus = CleanupStatus.None,
    val originalTranscript: String? = null,
    /** Set when a key could not be saved or removed securely. */
    val keyStoreError: Boolean = false,
    /** Providers whose key last failed to save, be read or be accepted, for the Errors filter. */
    val keyErrors: Set<CloudProvider> = emptySet(),
    /** True until a discarded recording has released the microphone. */
    val releasingMicrophone: Boolean = false,
    /** Newest first. */
    val history: List<HistoryEntry> = emptyList(),
    val retention: Retention = Retention.Month,
    /** The last history change could not be written; it is retried with the next change. */
    val historyError: Boolean = false,
    /** Audio another app shared, waiting for the user to confirm the upload. */
    val sharedAudio: SharedAudioOffer? = null,
    /** Cancelled Cloud recordings are kept in History for a later transcription. */
    val keepAudioOnCancel: Boolean = AppPreferences.DEFAULT_KEEP_AUDIO_ON_CANCEL,
    /** The History entry whose kept audio is being transcribed, if any. */
    val transcribingEntryId: String? = null,
    /** System resources the app holds now, oldest first (#1473). */
    val resourcesInUse: List<SystemResourceHold> = emptyList(),
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

    /** Cleanup runs only when switched on and the chosen model's provider has a key. */
    val cleanupReady: Boolean
        get() = cleanupEnabled && cleanupModel.provider in savedKeys
}

/** Deadlines and polling for the session's blocking work; tests shorten them. */
internal data class DictationTimings(
    val transcribeMs: Long = 180_000L,
    val cleanupMs: Long = 60_000L,
    val importMs: Long = 60_000L,
    val downloadCheckIntervalMs: Long = 5_000L,
    val downloadChecks: Int = 60,
)

/**
 * Orchestrates dictation: availability, recognition, Cloud capture and upload, and cleanup. History
 * writes belong to [DictationHistory], retries of kept audio to [HistoryRetry] and shared-audio
 * copies to [SharedAudioImporter]. Every collaborator is injected ([Factory] wires the production
 * ones), and all calls run on the main thread of [scope]; blocking work moves to [io] through
 * [CloudCapture].
 */
class DictationViewModel internal constructor(
    private val engine: SpeechEngine,
    recorders: RecorderFactory,
    private val cloud: CloudService,
    private val secrets: SecretStore,
    private val prefs: DictationPreferences,
    history: HistoryStore,
    private val sharedAudioSource: SharedAudioSource,
    private val cacheDir: File,
    private val recordingsDir: File,
    // The same context viewModelScope uses; closed with the ViewModel.
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val timings: DictationTimings = DictationTimings(),
    // Process-wide, so a recreated ViewModel shares the lane that releases its predecessor's microphone.
    retirement: RecorderRetirement = RecorderRetirement.shared,
    // Process-wide, so Settings and the keyboard list every hold the app has.
    private val resources: SystemResourceRegistry = SystemResourceRegistry.shared,
) : ViewModel(AutoCloseable { scope.cancel() }) {
    private val capture = CloudCapture(recorders, cacheDir, io, retirement, resources)
    private val sharedAudioImporter = SharedAudioImporter(capture, timings.importMs)
    private val historyRetry = HistoryRetry(cloud, secrets, capture, io, timings.transcribeMs)

    private val _state = MutableStateFlow(
        DictationUiState(
            chosenMode = prefs.chosenMode,
            cloudModel = CloudCatalog.transcriptionModel(prefs.cloudModelId),
            cleanupEnabled = prefs.cleanupEnabled,
            cleanupModel = CloudCatalog.cleanupModel(prefs.cleanupModelId),
            retention = prefs.retention,
            keepAudioOnCancel = prefs.keepAudioOnCancel,
        ),
    )

    private val historyOwner = DictationHistory(history, recordingsDir, scope, io) { entries, failed ->
        _state.update { it.copy(history = entries, historyError = failed) }
    }

    private var microphoneHold: SystemResourceToken? = null

    init {
        scope.launch {
            resources.holds.collect { holds -> _state.update { it.copy(resourcesInUse = holds) } }
        }
        historyOwner.load(prefs.retention)
    }
    val state: StateFlow<DictationUiState> = _state.asStateFlow()

    // Kept separate so microphone level updates only recompose the level indicator.
    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level.asStateFlow()

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
        if (!sharedAudioSource.accepts(uri)) {
            sessionModelId = _state.value.cloudModel.catalogId
            dispatch(DictationEvent.Start(RecognitionMode.Cloud))
            dispatch(DictationEvent.Error(DictationFailure.UnsupportedAudio))
            return
        }
        _state.update { it.copy(sharedAudio = SharedAudioOffer(uri, mimeType)) }
    }

    fun dismissSharedAudio() {
        _state.update { it.copy(sharedAudio = null) }
    }

    fun confirmSharedAudio() {
        val offer = _state.value.sharedAudio ?: return
        _state.update { it.copy(sharedAudio = null) }
        // Confirming takes priority over an optional cleanup; the transcript is already in History.
        if (_state.value.cleanup == CleanupStatus.Running) {
            work?.cancel()
            _state.update { it.copy(cleanup = CleanupStatus.None) }
        }
        transcribeSharedAudio(offer.uri, offer.mimeType)
    }

    private fun transcribeSharedAudio(uri: Uri, mimeType: String?) {
        val current = _state.value
        if (current.dictation.isActive || current.cleanup == CleanupStatus.Running) return
        val model = current.cloudModel
        val language = current.languageTag
        _state.update { it.copy(cleanup = CleanupStatus.None, originalTranscript = null) }
        sessionModelId = model.catalogId
        dispatch(DictationEvent.Start(RecognitionMode.Cloud))
        dispatch(DictationEvent.StopRequested)
        work = scope.launch {
            val file = File(cacheDir, "shared-${System.nanoTime()}")
            val event = try {
                val key = withContext(io) { secrets.read(model.provider.credentialId) }
                    ?: throw CloudException(DictationFailure.MissingKey, "No key")
                val format = sharedAudioImporter.import(
                    mimeType,
                    file,
                    providerType = { sharedAudioSource.type(uri) },
                    open = { sharedAudioSource.open(uri) },
                )
                DictationEvent.Final(
                    capture.call(timings.transcribeMs, model.provider) { call ->
                        cloud.transcribe(model, key, file, language, call, format)
                    },
                )
            } catch (e: RequestReleasedException) {
                DictationEvent.Cancelled
            } catch (e: CloudException) {
                noteKeyFailure(model.provider, e.failure)
                DictationEvent.Error(e.failure)
            } catch (e: GeneralSecurityException) {
                noteKeyFailure(model.provider, DictationFailure.KeyUnavailable)
                DictationEvent.Error(DictationFailure.KeyUnavailable)
            } catch (e: ProviderException) {
                noteKeyFailure(model.provider, DictationFailure.KeyUnavailable)
                DictationEvent.Error(DictationFailure.KeyUnavailable)
            } catch (e: IOException) {
                DictationEvent.Error(DictationFailure.Audio)
            } catch (e: SecurityException) {
                DictationEvent.Error(DictationFailure.Audio)
            } finally {
                capture.delete(file)
            }
            ensureActive()
            onEngineEvent(event)
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

    fun chooseCleanupModel(model: CleanupModel) {
        prefs.cleanupModelId = model.selectionId
        _state.update { it.copy(cleanupModel = model) }
    }

    fun setCleanupEnabled(enabled: Boolean) {
        prefs.cleanupEnabled = enabled
        _state.update { it.copy(cleanupEnabled = enabled) }
    }

    fun setKeepAudioOnCancel(enabled: Boolean) {
        prefs.keepAudioOnCancel = enabled
        _state.update { it.copy(keepAudioOnCancel = enabled) }
    }

    fun saveKey(provider: CloudProvider, key: String) =
        updateKeys(provider) { secrets.write(provider.credentialId, key.trim()) }

    fun removeKey(provider: CloudProvider) = updateKeys(provider) { secrets.remove(provider.credentialId) }

    private fun updateKeys(provider: CloudProvider, change: () -> Unit) {
        val ok = try {
            change()
            true
        } catch (e: GeneralSecurityException) {
            false
        } catch (e: ProviderException) {
            false
        }
        _state.update {
            it.copy(keyStoreError = !ok, keyErrors = if (ok) it.keyErrors - provider else it.keyErrors + provider)
        }
        refreshAvailability()
    }

    /** A provider that rejected its saved key, or whose key could not be read, shows under Errors. */
    private fun noteKeyFailure(provider: CloudProvider, failure: DictationFailure) {
        if (failure == DictationFailure.InvalidKey || failure == DictationFailure.KeyUnavailable) {
            _state.update { it.copy(keyErrors = it.keyErrors + provider) }
        }
    }

    private var downloadWatch: Job? = null

    /**
     * Requests the model, then rechecks support until it is installed or the wait ends, so Start
     * becomes available without leaving the app (the platform reports progress only via rechecks).
     */
    fun downloadOnDeviceModel() {
        engine.requestOnDeviceModel(_state.value.onDeviceLanguageTag)
        downloadWatch?.cancel()
        downloadWatch = scope.launch {
            repeat(timings.downloadChecks) {
                delay(timings.downloadCheckIntervalMs)
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
        val current = _state.value
        val capturing = current.dictation is DictationState.Starting || current.dictation is DictationState.Listening
        // Only a user cancel of a Cloud capture keeps audio: other modes never produce a file.
        val keep = current.keepAudioOnCancel && capturing &&
            current.dictation.modeOrNull() == RecognitionMode.Cloud && capture.current != null
        engine.cancel()
        work?.cancel()
        if (keep) keepCancelledRecording() else discardRecording()
        _state.update {
            it.copy(cleanup = if (it.cleanup == CleanupStatus.Running) CleanupStatus.None else it.cleanup)
        }
        dispatch(DictationEvent.Cancelled)
    }

    /** Asks the owner of a hold shown in Settings to let it go. */
    fun releaseResource(id: String) {
        resources.release(id)
    }

    /** Stops recordings and requests; nothing standing is held on Android, so this frees everything. */
    fun releaseEverything() {
        resources.releaseAll()
    }

    fun setRetention(retention: Retention) {
        prefs.retention = retention
        _state.update { it.copy(retention = retention) }
        historyOwner.refresh(retention)
    }

    fun deleteHistoryEntry(id: String) {
        historyOwner.remove(id, _state.value.retention)
    }

    fun clearHistory() {
        historyOwner.clear()
    }

    /** Re-reads and prunes history so the retention cutoff holds while the app stays open. */
    fun refreshHistory() {
        historyOwner.refresh(_state.value.retention)
    }

    // The model is fixed when the session starts, so later Settings changes cannot relabel it.
    private var sessionModelId: String? = null

    /**
     * Android does not let a foreground-only app keep the microphone once it leaves the screen, so
     * capture ends as a failure. Work that no longer needs the microphone (an upload) continues.
     */
    fun onLeftApp() {
        // A tile or shortcut start that has not happened yet must not start once the app is hidden.
        autoStartPending = false
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
        historyOwner.replaceSessionText(original, cleanedUp = false, _state.value.retention)
        _state.update {
            it.copy(
                dictation = done.copy(transcript = original),
                cleanup = CleanupStatus.None,
                originalTranscript = null,
            )
        }
    }

    private fun startCloud() {
        val started = capture.start(
            onLevel = { _level.value = it },
            onLimitReached = { rec -> scope.launch { if (capture.owns(rec)) stop() } },
            onCaptureFailed = { rec -> scope.launch { if (capture.owns(rec)) failCapture() } },
        )
        dispatch(if (started) DictationEvent.Ready else DictationEvent.Error(DictationFailure.Audio))
    }

    private fun failCapture() {
        discardRecording()
        dispatch(DictationEvent.Error(DictationFailure.Audio))
    }

    private fun finishCloud() {
        val rec = capture.current ?: return
        val file = rec.file
        // Settings stays open during a session, so use the model the recording started with.
        val model = sessionModelId?.let(CloudCatalog::transcriptionModel) ?: _state.value.cloudModel
        val language = _state.value.languageTag
        val modelId = sessionModelId
        work = scope.launch {
            var kept = false
            val event = try {
                // The recorder stays owned (and releasable by onCleared) until stop() has finished.
                val bytes = capture.stop(rec)
                reconcileMicrophoneHold()
                when {
                    bytes < 0 -> DictationEvent.Error(DictationFailure.Audio)
                    bytes < MIN_AUDIO_BYTES -> DictationEvent.Error(DictationFailure.NoSpeech)
                    else -> {
                        val key = withContext(io) { secrets.read(model.provider.credentialId) }
                        if (key == null) {
                            DictationEvent.Error(DictationFailure.InvalidKey)
                        } else {
                            DictationEvent.Final(
                                capture.call(timings.transcribeMs, model.provider) { call ->
                                    cloud.transcribe(model, key, file, language, call)
                                },
                            )
                        }
                    }
                }
            } catch (e: RequestReleasedException) {
                // Releasing the upload is a cancel, so honour "Keep audio when a recording is cancelled".
                if (_state.value.keepAudioOnCancel) {
                    kept = true
                    historyOwner.keepRecording(file, modelId, _state.value.retention)
                }
                DictationEvent.Cancelled
            } catch (e: CloudException) {
                noteKeyFailure(model.provider, e.failure)
                DictationEvent.Error(e.failure)
            } catch (e: GeneralSecurityException) {
                noteKeyFailure(model.provider, DictationFailure.KeyUnavailable)
                DictationEvent.Error(DictationFailure.KeyUnavailable)
            } catch (e: ProviderException) {
                noteKeyFailure(model.provider, DictationFailure.KeyUnavailable)
                DictationEvent.Error(DictationFailure.KeyUnavailable)
            } finally {
                capture.release(rec)
                reconcileMicrophoneHold()
                if (!kept) capture.delete(file)
            }
            // A cancelled upload must not deliver a late result into a newer session.
            ensureActive()
            onEngineEvent(event)
        }
    }

    /** Stops capture without a result. Ownership is kept until the recorder has really stopped. */
    private fun discardRecording() {
        val rec = capture.current ?: return
        _state.update { it.copy(releasingMicrophone = true) }
        scope.launch {
            capture.discard(rec)
            reconcileMicrophoneHold()
            _state.update { it.copy(releasingMicrophone = false) }
        }
    }

    /** Stops capture and moves a usable recording into History as a cancelled entry. */
    private fun keepCancelledRecording() {
        val rec = capture.current ?: return
        val file = rec.file
        val modelId = sessionModelId
        val retention = _state.value.retention
        _state.update { it.copy(releasingMicrophone = true) }
        scope.launch {
            val bytes = capture.stop(rec)
            reconcileMicrophoneHold()
            _state.update { it.copy(releasingMicrophone = false) }
            if (bytes < MIN_AUDIO_BYTES) {
                // Too short to contain a word, so there is nothing worth transcribing later.
                capture.delete(file)
                return@launch
            }
            historyOwner.keepRecording(file, modelId, retention)
        }
    }

    /**
     * Transcribes a cancelled recording kept in History with the current cloud model and saved key.
     * Success replaces the entry with the transcript and deletes the audio; a failure keeps both.
     */
    fun transcribeHistoryEntry(id: String) {
        val current = _state.value
        if (current.dictation.isActive || current.transcribingEntryId != null) return
        val entry = current.history.firstOrNull { it.id == id } ?: return
        if (entry.audioPath == null) return
        val model = current.cloudModel
        val language = current.languageTag
        _state.update { it.copy(transcribingEntryId = id) }
        scope.launch {
            val updated = historyRetry.transcribe(entry, model, language)
            val retention = _state.value.retention
            // Cleared with the updated entry, so Transcribe never reappears on the stale one.
            try {
                historyOwner.replace(updated, retention)
            } finally {
                _state.update { it.copy(transcribingEntryId = null) }
            }
        }
    }

    /** The microphone is held while a session captures, and until a Cloud recorder has really stopped. */
    private fun reconcileMicrophoneHold() {
        val dictation = _state.value.dictation
        if (dictation.holdsMicrophone || capture.current != null) {
            if (microphoneHold != null) return
            val mode = dictation.modeOrNull()
            microphoneHold = resources.acquire(
                kind = SystemResourceKind.Microphone,
                title = "Dictation recording",
                reason = when (mode) {
                    RecognitionMode.Cloud -> "Recording audio to send to your cloud provider"
                    RecognitionMode.SpeechService -> "Listening through the speech recognition service"
                    else -> "Listening with on-device recognition"
                },
                owner = "DictationViewModel",
                releaseTitle = "Stop recording",
                release = { cancel() },
            )
        } else {
            microphoneHold?.end()
            microphoneHold = null
        }
    }

    private fun onEngineEvent(event: DictationEvent) {
        dispatch(event)
        val done = _state.value.dictation as? DictationState.Done ?: return
        if (event is DictationEvent.Final && _state.value.cleanupReady) runCleanup(done)
    }

    private fun runCleanup(done: DictationState.Done) {
        _state.update { it.copy(cleanup = CleanupStatus.Running) }
        work = scope.launch {
            var released = false
            val cleaned = try {
                val model = _state.value.cleanupModel
                val key = withContext(io) { secrets.read(model.provider.credentialId) }
                key?.let {
                    capture.call(timings.cleanupMs, model.provider) { call ->
                        cloud.cleanup(model, it, done.transcript, call)
                    }
                }
            } catch (e: RequestReleasedException) {
                released = true
                null
            } catch (e: CloudException) {
                null
            } catch (e: GeneralSecurityException) {
                null
            } catch (e: ProviderException) {
                null
            }
            if (_state.value.dictation != done) return@launch
            _state.update {
                if (released) {
                    it.copy(cleanup = CleanupStatus.None)
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
            if (!cleaned.isNullOrBlank()) {
                historyOwner.replaceSessionText(cleaned, cleanedUp = true, _state.value.retention)
            }
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
        reconcileMicrophoneHold()
        if (!before.isActive || after.isActive) return
        // A session just ended: record it now, so it survives even if optional cleanup never finishes.
        historyOwner.recordSession(after, sessionModelId, _state.value.retention)
    }

    override fun onCleared() {
        engine.close()
        microphoneHold?.end()
        microphoneHold = null
        capture.close()
    }

    companion object {
        /** About a quarter of a second; shorter recordings cannot contain a word. */
        private const val MIN_AUDIO_BYTES = WavFormat.BYTES_PER_SECOND / 4

        /** Wires the production collaborators. */
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val application = checkNotNull(this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY])
                create(application)
            }
        }

        private fun create(application: Application) = DictationViewModel(
            engine = AndroidSpeechEngine(application),
            recorders = { file, onLevel, onLimitReached, onCaptureFailed ->
                WavRecorder(file, onLevel, onLimitReached, onCaptureFailed)
            },
            cloud = CloudClient(),
            secrets = KeystoreSecretStore.create(application),
            prefs = AppPreferences(application),
            history = HistoryStore(
                AtomicHistoryFile(File(application.filesDir, "history.json")),
                deleteAudio = { File(it).delete() },
            ),
            sharedAudioSource = ContentSharedAudioSource(application),
            cacheDir = application.cacheDir,
            recordingsDir = File(application.filesDir, "recordings"),
        )
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
