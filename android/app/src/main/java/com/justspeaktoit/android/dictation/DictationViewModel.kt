package com.justspeaktoit.android.dictation

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.justspeaktoit.android.JustSpeakApplication
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudClient
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.RecorderFactory
import com.justspeaktoit.android.cloud.WavRecorder
import com.justspeaktoit.android.corrections.AutoCorrectionLearner
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.history.AtomicHistoryFile
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.security.KeystoreSecretStore
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.settings.DictationPreferences
import com.justspeaktoit.android.settings.DictationProfile
import com.justspeaktoit.android.settings.RawConfigurationValues
import com.justspeaktoit.android.settings.RecordingCue
import com.justspeaktoit.android.settings.RecordingSoundSettings
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.security.GeneralSecurityException
import java.security.ProviderException

/**
 * The dictation screen's state. It projects its owners into one [DictationUiState] and routes the
 * screen's actions to them: [DictationEngineSelector] chooses the mode and checks availability,
 * [DictationSessionController] runs sessions and holds the microphone, [DictationHistory] writes
 * History, [HistoryRetry] transcribes kept audio and [SharedAudioImporter] copies shared audio. Every
 * collaborator is injected ([Factory] wires the production ones), and all calls run on the main thread
 * of [scope]; blocking work moves to [io] through [CloudCapture].
 *
 * While a session captures or saves its audio, [foreground] runs a microphone foreground service so
 * the session keeps going with the screen off or another app in front, and [interruptions] reports
 * calls, audio focus changes and microphone route changes.
 */
class DictationViewModel internal constructor(
    private val engine: SpeechEngine,
    recorders: RecorderFactory,
    cloud: CloudService,
    private val secrets: SecretStore,
    private val prefs: DictationPreferences,
    history: HistoryStore,
    private val sharedAudioSource: SharedAudioSource,
    cacheDir: File,
    recordingsDir: File,
    // The same context viewModelScope uses; closed with the ViewModel.
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    io: CoroutineDispatcher = Dispatchers.IO,
    timings: DictationTimings = DictationTimings(),
    // Process-wide, so a recreated ViewModel shares the lane that releases its predecessor's microphone.
    retirement: RecorderRetirement = RecorderRetirement.shared,
    // Process-wide, so Settings and the keyboard list every hold the app has.
    private val resources: SystemResourceRegistry = SystemResourceRegistry.shared,
    private val interruptions: AudioInterruptions = NoAudioInterruptions,
    private val foreground: ForegroundSession = NoForegroundSession,
    // Told when a dictation produces a transcript; only its mode and model are passed, never the text.
    private val onTranscriptionSucceeded: (RecognitionMode, CloudModel) -> Unit = { _, _ -> },
    private val sounds: RecordingSoundOutput? = null,
) : ViewModel(AutoCloseable { scope.cancel() }) {
    private val capture = CloudCapture(recorders, cacheDir, io, retirement, resources)
    private val sharedAudioImporter = SharedAudioImporter(capture, timings.importMs)
    private val historyRetry = HistoryRetry(cloud, secrets, capture, io, timings.transcribeMs)

    /** Shares the keyboard's preferences, so edits it learned appear on [refreshLearnedCorrections]. */
    private val learner = AutoCorrectionLearner(prefs)

    private val selector: DictationEngineSelector = DictationEngineSelector(
        engine,
        secrets,
        prefs,
        scope,
        timings,
        sessionActive = { session.state.dictation.isActive },
        publish = ::onSelection,
    )

    private val _state: MutableStateFlow<DictationUiState> = MutableStateFlow(
        DictationUiState(
            cleanupEnabled = prefs.cleanupEnabled,
            cleanupModel = CloudCatalog.cleanupModel(prefs.cleanupModelId),
            retention = prefs.retention,
            keepAudioOnCancel = prefs.keepAudioOnCancel,
            silence = prefs.silence,
            keepRecordings = prefs.keepRecordings,
            corrections = prefs.corrections,
            learnCorrections = prefs.learnCorrections,
            correctionPromotionThreshold = prefs.correctionPromotionThreshold,
            correctionCandidates = learner.pending(),
            cleanupPrompt = prefs.cleanupPrompt,
            profiles = prefs.profiles,
            recordingSounds = prefs.recordingSounds,
        ).withSelection(selector.selection),
    )
    val state: StateFlow<DictationUiState> = _state.asStateFlow()

    private val historyOwner = DictationHistory(history, recordingsDir, scope, io) { entries, failed ->
        _state.update { it.copy(history = entries, historyError = failed) }
    }

    private val session: DictationSessionController = DictationSessionController(
        engine = engine,
        capture = capture,
        requests = SessionRequests(cloud, secrets, capture, io, timings, onKeyFailure = { provider, _ ->
            _state.update { it.copy(keyErrors = it.keyErrors + provider) }
        }),
        history = historyOwner,
        resources = resources,
        scope = scope,
        cacheDir = cacheDir,
        settings = object : SessionSettings {
            override val retention: Retention get() = _state.value.retention
            override val keepAudioOnCancel: Boolean get() = _state.value.keepAudioOnCancel
            override val keepRecordings: Boolean get() = _state.value.keepRecordings
            override val cleanupModel: CleanupModel?
                get() = _state.value.let { if (it.cleanupReady) it.sessionCleanupModel else null }
            override val cleanupPrompt: String? get() = _state.value.sessionCleanupPrompt
            override val corrections: List<CorrectionRule> get() = _state.value.corrections
            override val silence: SilenceSettings get() = _state.value.silence
        },
        cues = { cue ->
            val choice = _state.value.recordingSounds
            if (choice.enabled) sounds?.play(cue, choice.profile, choice.gain) ?: 0L else 0L
        },
        publish = { s ->
            // Before the screen sees the change, so the service and watching are in step with it.
            onSessionChanged(s)
            val finished = s.dictation as? DictationState.Done
            if (finished != null && _state.value.dictation !is DictationState.Done) {
                // The session's own model: a profile can override the Settings one for a single session.
                onTranscriptionSucceeded(finished.mode, CloudCatalog.transcriptionModel(session.sessionModelId))
            }
            _state.update {
                it.copy(
                    dictation = s.dictation,
                    cleanup = s.cleanup,
                    originalTranscript = s.originalTranscript,
                    releasingMicrophone = s.releasingMicrophone,
                    paused = s.paused,
                )
            }
        },
    )

    /** Kept separate so microphone level updates only recompose the level indicator. */
    val level: StateFlow<Float> = session.level

    private var autoStartPending = false

    private var appVisible = true
    private var watchingInterruptions = false
    private var foregroundPhase: ForegroundPhase? = null

    /** True while Android lets the foreground service keep the session running off screen. */
    private var foregroundActive = false

    private val foregroundListener = object : ForegroundDictation.Listener {
        override fun onStopRequested() = stop()

        override fun onForegroundRefused() {
            foregroundActive = false
            foreground.hide()
            if (!appVisible) session.leaveApp()
        }
    }

    init {
        scope.launch {
            resources.holds.collect { holds -> _state.update { it.copy(resourcesInUse = holds) } }
        }
        historyOwner.load(prefs.retention, capture::recoverable)
    }

    /** Called whenever the screen starts, so newly installed models, services or keys are noticed. */
    fun refreshAvailability() = selector.refresh()

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

    private fun onSelection(selection: EngineSelection) {
        _state.update { it.withSelection(selection) }
        // An auto-start waits only for an availability check, so any settled selection may start it.
        maybeAutoStart()
    }

    /**
     * Audio shared by another app is only uploaded after the user confirms, so no app can spend
     * the user's cloud credit by sending audio here.
     */
    fun offerSharedAudio(uri: Uri, mimeType: String?) {
        if (_state.value.dictation.isActive) return
        if (!sharedAudioSource.accepts(uri)) {
            session.rejectSharedAudio(_state.value.sessionCloudModel)
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
        session.cancelCleanup()
        val current = _state.value
        session.transcribeSharedAudio(current.sessionCloudModel, current.languageTag) { file ->
            sharedAudioImporter.import(
                offer.mimeType,
                file,
                providerType = { sharedAudioSource.type(offer.uri) },
                open = { sharedAudioSource.open(offer.uri) },
            )
        }
    }

    fun chooseMode(mode: RecognitionMode) = selector.chooseMode(mode)

    fun chooseCloudModel(model: CloudModel) = selector.chooseCloudModel(model)

    fun chooseLanguage(id: String) = selector.chooseLanguage(id)

    /** Saves [rules] in order; they apply from the next final transcript. */
    fun setCorrections(rules: List<CorrectionRule>) {
        prefs.corrections = rules
        _state.update { it.copy(corrections = rules) }
    }

    /** Saves the shared start/stop sound settings; they apply from the next cue. */
    fun setRecordingSounds(choice: RecordingSoundSettings) {
        prefs.recordingSounds = choice
        _state.update { it.copy(recordingSounds = choice) }
    }

    /** Plays the chosen profile's start cue so the user can hear the profile and volume. */
    fun previewRecordingSound() {
        val choice = _state.value.recordingSounds
        sounds?.play(RecordingCue.Start, choice.profile, choice.gain)
    }

    fun setLearnCorrections(enabled: Boolean) {
        prefs.learnCorrections = enabled
        _state.update { it.copy(learnCorrections = enabled) }
    }

    fun setCorrectionPromotionThreshold(threshold: Int) {
        prefs.correctionPromotionThreshold = threshold
        _state.update { it.copy(correctionPromotionThreshold = prefs.correctionPromotionThreshold) }
    }

    /** Adds a learned edit to the personal corrections now. */
    fun acceptCorrectionCandidate(id: String) {
        learner.accept(id)
        refreshLearnedCorrections()
    }

    /** Hides a learned edit; the same edit is not suggested again. */
    fun dismissCorrectionCandidate(id: String) {
        learner.dismiss(id)
        refreshLearnedCorrections()
    }

    fun clearCorrectionCandidates() {
        learner.clear()
        refreshLearnedCorrections()
    }

    /**
     * Re-reads what the keyboard may have learned while the app was elsewhere: new candidates and
     * corrections promoted from them.
     */
    fun refreshLearnedCorrections() {
        _state.update { it.copy(corrections = prefs.corrections, correctionCandidates = learner.pending()) }
    }

    fun chooseCleanupModel(model: CleanupModel) {
        prefs.cleanupModelId = model.selectionId
        _state.update { it.copy(cleanupModel = model) }
    }

    fun setCleanupEnabled(enabled: Boolean) {
        prefs.cleanupEnabled = enabled
        _state.update { it.copy(cleanupEnabled = enabled) }
    }

    /** A blank prompt restores the built-in one. Applies from the next cleanup. */
    fun setCleanupPrompt(prompt: String) {
        val saved = prompt.takeIf { it.isNotBlank() }
        prefs.cleanupPrompt = saved
        _state.update { it.copy(cleanupPrompt = saved) }
    }

    /** Adds [profile], or replaces the saved one with its id. Applies from the next session. */
    fun saveProfile(profile: DictationProfile) {
        val current = prefs.profiles
        val updated = if (current.any { it.id == profile.id }) {
            current.map { if (it.id == profile.id) profile else it }
        } else {
            current + profile
        }
        storeProfiles(updated)
    }

    /** Deleting the active profile leaves no profile chosen. */
    fun deleteProfile(id: String) {
        if (prefs.activeProfileId == id) prefs.activeProfileId = null
        storeProfiles(prefs.profiles.filterNot { it.id == id })
    }

    /** Ignored while dictating, so a running session keeps the settings it started with. */
    fun chooseProfile(id: String?) = selector.chooseProfile(id)

    private fun storeProfiles(profiles: List<DictationProfile>) {
        prefs.profiles = profiles
        _state.update { it.copy(profiles = profiles) }
        selector.refresh()
    }

    fun setKeepAudioOnCancel(enabled: Boolean) {
        prefs.keepAudioOnCancel = enabled
        _state.update { it.copy(keepAudioOnCancel = enabled) }
    }

    /**
     * Applies validated raw-configuration changes (see [RawConfiguration]) through the same paths as the
     * Settings controls, all of them or, while a dictation is running, none: returns false then.
     */
    fun applyConfiguration(changes: Map<String, Any?>): Boolean {
        if (_state.value.dictation.isActive) return false
        changes.forEach { (key, value) ->
            when (key) {
                "chosen_mode" -> selector.chooseMode((value as String?)?.let(RecognitionMode::valueOf))
                "cloud_model" -> chooseCloudModel(CloudCatalog.transcriptionModel(value as String))
                "preferredLocale" -> chooseLanguage(value as String)
                "personal_corrections" ->
                    setCorrections(RawConfigurationValues.corrections(value as Map<*, *>, _state.value.corrections))
                "cleanup_enabled" -> setCleanupEnabled(value as Boolean)
                "cleanup_model" -> chooseCleanupModel(CloudCatalog.cleanupModel(value as String))
                "keepAudioOnCancel" -> setKeepAudioOnCancel(value as Boolean)
                "history_retention" -> setRetention(Retention.valueOf(value as String))
                else -> error("No raw-configuration binding for $key")
            }
        }
        return true
    }

    /** Applies from the next Cloud recording; one under way keeps the settings it started with. */
    fun setSilence(settings: SilenceSettings) {
        val clamped = SilenceSettings.of(settings.enabled, settings.threshold, settings.durationSeconds)
        prefs.silence = clamped
        _state.update { it.copy(silence = clamped) }
    }

    /** Applies from the next Cloud recording; recordings already in History stay until removed. */
    fun setKeepRecordings(enabled: Boolean) {
        prefs.keepRecordings = enabled
        _state.update { it.copy(keepRecordings = enabled) }
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

    fun downloadOnDeviceModel() = selector.downloadOnDeviceModel()

    fun start() {
        val current = _state.value
        val mode = current.activeMode ?: return
        if (!current.canStart) return
        session.start(selector.plan(mode))
    }

    fun stop() = session.stop()

    fun cancel() = session.cancel()

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
        historyOwner.refresh(retention, capture::recoverable)
    }

    fun deleteHistoryEntry(id: String) {
        historyOwner.remove(id, _state.value.retention)
    }

    /** Clears History; [keepRecordings] keeps the entries that hold a recording. */
    fun clearHistory(keepRecordings: Boolean = false) {
        historyOwner.clear(keepRecordings, _state.value.retention)
    }

    /** Re-reads and prunes history so the retention cutoff holds while the app stays open. */
    fun refreshHistory() {
        historyOwner.refresh(_state.value.retention, capture::recoverable)
    }

    fun onEnteredApp() {
        appVisible = true
    }

    /**
     * A session protected by the foreground service carries on; without it, capture cannot continue
     * once the app is hidden (see [DictationSessionController.leaveApp]).
     */
    fun onLeftApp() {
        appVisible = false
        // A tile or shortcut start that has not happened yet must not start once the app is hidden.
        autoStartPending = false
        if (foregroundActive) return
        session.leaveApp()
    }

    fun clearResult() = session.clearResult()

    fun showOriginal() = session.showOriginal()

    /**
     * Transcribes a cancelled recording kept in History with the current cloud model and saved key.
     * Success replaces the entry with the transcript and deletes the audio; a failure keeps both.
     */
    fun transcribeHistoryEntry(id: String) {
        val current = _state.value
        if (current.dictation.isActive || current.transcribingEntryId != null) return
        val entry = current.history.firstOrNull { it.id == id } ?: return
        if (entry.audioPath == null) return
        val model = current.sessionCloudModel
        val language = current.languageTag
        _state.update { it.copy(transcribingEntryId = id) }
        scope.launch {
            val updated = historyRetry.transcribe(entry, model, language, current.corrections, current.keepRecordings)
            val retention = _state.value.retention
            // Cleared with the updated entry, so Transcribe never reappears on the stale one.
            try {
                historyOwner.replace(updated, retention)
            } finally {
                _state.update { it.copy(transcribingEntryId = null) }
            }
        }
    }

    /** Keeps the foreground service and interruption watching in step with the session. */
    private fun onSessionChanged(s: SessionState) {
        val capturing = s.dictation is DictationState.Starting || s.dictation is DictationState.Listening
        if (capturing != watchingInterruptions) {
            watchingInterruptions = capturing
            if (capturing) {
                interruptions.start(requestFocus = s.dictation.modeOrNull() == RecognitionMode.Cloud, ::onInterruption)
            } else {
                interruptions.stop()
            }
        }
        val phase = foregroundPhase(s)
        if (phase == foregroundPhase) return
        foregroundPhase = phase
        if (phase == null) {
            foregroundActive = false
            foreground.hide()
            if (ForegroundDictation.listener === foregroundListener) ForegroundDictation.listener = null
        } else {
            ForegroundDictation.listener = foregroundListener
            foregroundActive = foreground.show(phase)
        }
    }

    private fun onInterruption(signal: InterruptionSignal) {
        if (!session.isCapturing) return
        val mode = session.state.dictation.modeOrNull() ?: return
        when (val action = InterruptionPolicy.decide(signal, mode, session.state.paused)) {
            InterruptionAction.None -> Unit
            InterruptionAction.Pause -> session.pause()
            InterruptionAction.Resume -> session.resume()
            is InterruptionAction.Stop -> session.interrupt(action.failure)
        }
    }

    override fun onCleared() {
        interruptions.stop()
        if (foregroundPhase != null) foreground.hide()
        if (ForegroundDictation.listener === foregroundListener) ForegroundDictation.listener = null
        engine.close()
        session.close()
        sounds?.close()
    }

    companion object {
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
            interruptions = AndroidAudioInterruptions(application),
            foreground = AndroidForegroundSession(application),
            onTranscriptionSucceeded = { mode, model ->
                (application as? JustSpeakApplication)?.telemetry?.transcriptionSucceeded(mode, model)
            },
            sounds = RecordingSoundPlayer(application),
        )
    }
}

private fun DictationUiState.withSelection(selection: EngineSelection) = copy(
    chosenMode = selection.chosenMode,
    cloudModel = selection.cloudModel,
    languageId = selection.languageId,
    languageTag = selection.languageTag,
    onDeviceLanguageTag = selection.onDeviceLanguageTag,
    savedKeys = selection.savedKeys,
    options = selection.options,
    checkingAvailability = selection.checking,
    profile = selection.profile,
)
