package com.justspeaktoit.android.dictation

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.justspeaktoit.android.JustSpeakApplication
import com.justspeaktoit.android.cloud.AndroidAudioInputs
import com.justspeaktoit.android.cloud.AudioInputSource
import com.justspeaktoit.android.cloud.BalanceDirectory
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudClient
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.NoAudioInputs
import com.justspeaktoit.android.cloud.ProviderBalanceClient
import com.justspeaktoit.android.cloud.ProviderBalanceClients
import com.justspeaktoit.android.cloud.ProviderBalanceStore
import com.justspeaktoit.android.cloud.RecorderFactory
import com.justspeaktoit.android.cloud.WavRecorder
import com.justspeaktoit.android.corrections.AutoCorrectionLearner
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.history.AtomicHistoryFile
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.security.KeystoreSecretStore
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.AppAppearance
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.settings.DictationPreferences
import com.justspeaktoit.android.settings.DictationProfile
import com.justspeaktoit.android.settings.RawConfigurationValues
import com.justspeaktoit.android.settings.RecordingCue
import com.justspeaktoit.android.settings.RecordingSoundProfile
import com.justspeaktoit.android.settings.RecordingSoundSettings
import com.justspeaktoit.android.sync.AndroidHistorySync
import com.justspeaktoit.android.sync.HistorySyncAvailability
import com.justspeaktoit.android.sync.HistorySyncService
import com.justspeaktoit.android.sync.HistorySyncStatus
import com.justspeaktoit.android.sync.SyncHistoryEntries
import com.justspeaktoit.android.transfer.ConfigArchiveException
import com.justspeaktoit.android.transfer.ConfigExporter
import com.justspeaktoit.android.transfer.ConfigImportApplier
import com.justspeaktoit.android.transfer.ConfigImporter
import com.justspeaktoit.android.transfer.ConfigTransferFiles
import com.justspeaktoit.android.transfer.ConfigTransferState
import com.justspeaktoit.android.transfer.ImportPlan
import com.justspeaktoit.android.transfer.TransferOutcome
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
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
    // The microphones Settings offers; the recorder factory routes to the chosen one itself.
    private val audioInputs: AudioInputSource = NoAudioInputs,
    // provider_balances.json and Android's billing transports; empty shows no balance lines.
    balanceDirectory: BalanceDirectory = BalanceDirectory.EMPTY,
    balanceClients: List<ProviderBalanceClient> = emptyList(),
    handsFreeMicrophone: HandsFreeMicrophone = NoHandsFreeMicrophone,
    // Builds opt-in History sync over this ViewModel's History; null leaves sync out of the app.
    historySync: (SyncHistoryEntries) -> HistorySyncService? = { null },
) : ViewModel(AutoCloseable { scope.cancel() }) {
    /** Hands-free dictation (#1632): its recordings take their audio from its microphone, pre-roll first. */
    private val handsFree = HandsFreeDictation(
        microphone = handsFreeMicrophone,
        resources = resources,
        scope = scope,
        onSpeech = ::onHandsFreeSpeech,
        onChanged = ::onHandsFreeChanged,
    )

    private val capture = CloudCapture(
        { file, onLevel, onLimitReached, onCaptureFailed ->
            handsFree.recorder(file, onLevel, onLimitReached, onCaptureFailed)
                ?: recorders.create(file, onLevel, onLimitReached, onCaptureFailed)
        },
        cacheDir,
        io,
        retirement,
        resources,
    )
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
            handsFreeEnabled = prefs.handsFreeEnabled,
            keepRecordings = prefs.keepRecordings,
            corrections = prefs.corrections,
            learnCorrections = prefs.learnCorrections,
            correctionPromotionThreshold = prefs.correctionPromotionThreshold,
            correctionCandidates = learner.pending(),
            cleanupPrompt = prefs.cleanupPrompt,
            profiles = prefs.profiles,
            recordingSounds = prefs.recordingSounds,
            audioInputId = prefs.audioInputId,
            audioInputs = audioInputs.inputs(),
            appearance = prefs.appearance,
            dynamicColor = prefs.dynamicColor,
        ).withSelection(selector.selection),
    )
    val state: StateFlow<DictationUiState> = _state.asStateFlow()

    private val balances = ProviderBalanceStore(
        directory = balanceDirectory,
        clients = balanceClients,
        readKey = secrets::read,
        scope = scope,
        io = io,
        publish = { entries -> _state.update { it.copy(balances = entries) } },
    )

    init {
        _state.update {
            it.copy(
                balanceAccounts = balanceDirectory.accounts.associateBy { account -> account.primaryCredentialId },
                checkableBalances = balanceDirectory.accounts.filter(balances::canCheck).map { account -> account.id }
                    .toSet(),
            )
        }
    }

    private val historyOwner = DictationHistory(
        history,
        recordingsDir,
        scope,
        io,
        onLocalChange = { requestHistorySync() },
    ) { entries, failed ->
        _state.update { it.copy(history = entries, historyError = failed) }
    }

    // One thread owns the transfer files, so dismissing an import never deletes a newer one's files.
    @OptIn(ExperimentalCoroutinesApi::class)
    private val transferIo = io.limitedParallelism(1)
    private val transferFiles = ConfigTransferFiles(File(cacheDir, "config-transfer"))
    private val importApplier = ConfigImportApplier(prefs, secrets, recordingsDir, transferIo) { retention, change ->
        historyOwner.importEntries(retention, change)
    }

    /** The import the preview describes, applied only when the user confirms it. */
    private var pendingImport: ImportPlan? = null

    private val sync: HistorySyncService? = historySync(
        object : SyncHistoryEntries {
            override suspend fun snapshot(): List<HistoryEntry> = historyOwner.syncSnapshot(_state.value.retention)

            override suspend fun <T> update(transform: (List<HistoryEntry>) -> Pair<List<HistoryEntry>, T>): T =
                historyOwner.syncUpdate(_state.value.retention, transform)
        },
    )

    /** History sync's sign-in and progress, for Settings. */
    val historySyncStatus: StateFlow<HistorySyncStatus> =
        sync?.status ?: MutableStateFlow(HistorySyncStatus(HistorySyncAvailability.MissingToken)).asStateFlow()

    private var historySignIn: Job? = null
    private var pendingHistorySync: Job? = null

    private val session: DictationSessionController = DictationSessionController(
        engine = engine,
        capture = capture,
        requests = SessionRequests(cloud, secrets, capture, io, timings, onKeyFailure = { provider, failure ->
            _state.update {
                it.copy(
                    keyErrors = it.keyErrors + provider,
                    rejectedKeys = if (failure == DictationFailure.InvalidKey) {
                        it.rejectedKeys + provider
                    } else {
                        it.rejectedKeys
                    },
                )
            }
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
            // A hands-free recording always ends on silence, after the user's silence duration.
            override val silence: SilenceSettings
                get() = _state.value.silence.let { if (handsFree.startingUtterance) it.copy(enabled = true) else it }
        },
        cues = { cue ->
            val choice = _state.value.recordingSounds
            // Hands-free plays no cues, as on the desktop: they would be heard by the listening microphone.
            if (choice.enabled && !handsFree.armed) sounds?.play(cue, choice.profile, choice.gain) ?: 0L else 0L
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

    private val inputWatch = audioInputs.watch { _state.update { it.copy(audioInputs = audioInputs.inputs()) } }
    /** Speech started while availability was being checked; the recording starts once it settles. */
    private var handsFreeStartPending = false

    private var appVisible = true
    private var watchingInterruptions = false
    private var foregroundPhase: ForegroundPhase? = null

    /** True while Android lets the foreground service keep the session running off screen. */
    private var foregroundActive = false

    private val foregroundListener = object : ForegroundDictation.Listener {
        // Stop ends a hands-free recording and keeps listening; while only listening, it turns hands-free off.
        override fun onStopRequested() = if (session.isCapturing || !handsFree.armed) stop() else turnOffHandsFree()

        override fun onForegroundRefused() {
            foregroundActive = false
            foreground.hide()
            if (!appVisible) {
                session.leaveApp()
                if (handsFree.armed) handsFree.disarm(failed = true)
            }
        }
    }

    init {
        scope.launch {
            resources.holds.collect { holds -> _state.update { it.copy(resourcesInUse = holds) } }
        }
        historyOwner.load(prefs.retention, capture::recoverable)
        sync?.let { service ->
            scope.launch {
                service.prepare()
                service.sync()
            }
        }
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
        if (!selection.checking && handsFree.armed && _state.value.activeMode != RecognitionMode.Cloud) {
            // Only Cloud recordings can keep the pre-roll.
            handsFree.disarm()
        } else if (!selection.checking && handsFreeStartPending) {
            startHandsFreeUtterance()
        }
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
                "handsFreeDictationEnabled" -> setHandsFree(value as Boolean)
                "history_retention" -> setRetention(Retention.valueOf(value as String))
                "keepRecordingsInHistory" -> setKeepRecordings(value as Boolean)
                "silenceDetectionEnabled" -> setSilence(_state.value.silence.copy(enabled = value as Boolean))
                "silenceThreshold" -> setSilence(_state.value.silence.copy(threshold = value as Double))
                "silenceDuration" -> setSilence(_state.value.silence.copy(durationSeconds = value as Double))
                "autoCorrectionsEnabled" -> setLearnCorrections(value as Boolean)
                "autoCorrectionsPromotionThreshold" -> setCorrectionPromotionThreshold((value as Long).toInt())
                "recordingSoundsEnabled" ->
                    setRecordingSounds(_state.value.recordingSounds.copy(enabled = value as Boolean))
                "recordingSoundProfile" -> setRecordingSounds(
                    _state.value.recordingSounds.copy(profile = RecordingSoundProfile.fromId(value as String)),
                )
                "recordingSoundVolume" ->
                    setRecordingSounds(_state.value.recordingSounds.copy(volume = (value as Double).toFloat()))
                "appearance" -> setAppearance(AppAppearance.fromRawValue(value as String), _state.value.dynamicColor)
                "dynamicColor" -> setAppearance(_state.value.appearance, value as Boolean)
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

    /** The `AudioInput.id` the next Cloud recording uses, or null for the system default. */
    fun setAudioInput(id: String?) {
        prefs.audioInputId = id
        _state.update { it.copy(audioInputId = id, audioInputs = audioInputs.inputs()) }
    }

    /** Turning hands-free off also stops it listening; turning it on takes effect from the next tap. */
    fun setHandsFree(enabled: Boolean) {
        prefs.handsFreeEnabled = enabled
        _state.update { it.copy(handsFreeEnabled = enabled) }
        if (!enabled) handsFree.disarm()
    }

    fun setAppearance(appearance: AppAppearance, dynamicColor: Boolean) {
        prefs.appearance = appearance
        prefs.dynamicColor = dynamicColor
        _state.update { it.copy(appearance = appearance, dynamicColor = dynamicColor) }
    }

    /** Applies from the next Cloud recording; recordings already in History stay until removed. */
    fun setKeepRecordings(enabled: Boolean) {
        prefs.keepRecordings = enabled
        _state.update { it.copy(keepRecordings = enabled) }
    }

    fun saveKey(provider: CloudProvider, key: String) {
        if (updateKeys(provider) { secrets.write(provider.credentialId, key.trim()) }) {
            balances.refresh(provider.credentialId)
        }
    }

    fun removeKey(provider: CloudProvider) {
        updateKeys(provider) { secrets.remove(provider.credentialId) }
    }

    /** Checks every saved key's balance, as the Apple key pages do when they open. */
    fun refreshBalances() = balances.refreshSaved(_state.value.savedKeys.map { it.credentialId }.toSet())

    fun checkBalance(provider: CloudProvider) = balances.refresh(provider.credentialId)

    private fun updateKeys(provider: CloudProvider, change: () -> Unit): Boolean {
        balances.credentialChanged(provider.credentialId)
        val ok = try {
            change()
            true
        } catch (e: GeneralSecurityException) {
            false
        } catch (e: ProviderException) {
            false
        }
        _state.update {
            it.copy(
                keyStoreError = !ok,
                keyErrors = if (ok) it.keyErrors - provider else it.keyErrors + provider,
                rejectedKeys = if (ok) it.rejectedKeys - provider else it.rejectedKeys,
            )
        }
        refreshAvailability()
        return ok
    }

    fun downloadOnDeviceModel() = selector.downloadOnDeviceModel()

    /** Records now or, with hands-free on in Cloud mode, starts listening for speech. */
    fun start() {
        val current = _state.value
        val mode = current.activeMode ?: return
        if (!current.canStart || handsFree.armed) return
        if (current.armsHandsFree) {
            session.clearResult()
            handsFree.arm()
        } else {
            session.start(selector.plan(mode))
        }
    }

    /** Stops listening; a hands-free recording under way stops and is transcribed. */
    fun turnOffHandsFree() = handsFree.disarm()

    private fun onHandsFreeSpeech() {
        if (_state.value.checkingAvailability) handsFreeStartPending = true else startHandsFreeUtterance()
    }

    private fun startHandsFreeUtterance() {
        handsFreeStartPending = false
        if (!handsFree.startingUtterance) return
        val current = _state.value
        if (!current.canStart || current.activeMode != RecognitionMode.Cloud) {
            handsFree.disarm(failed = true)
            return
        }
        session.start(selector.plan(RecognitionMode.Cloud))
        // A recording that could not start leaves the session failed, which turns hands-free off.
        if (handsFree.recordingUtterance) handsFree.utteranceStarted() else handsFree.disarm(failed = true)
    }

    private fun onHandsFreeChanged(status: HandsFreeStatus) {
        val wasRecording = _state.value.handsFree == HandsFreeStatus.Recording
        _state.update { it.copy(handsFree = status) }
        if (!handsFree.armed) {
            handsFreeStartPending = false
            // Its audio stopped with the microphone, so transcribe what it has.
            if (wasRecording && session.isCapturing) session.stop()
        }
        syncForeground(session.state)
    }

    /** After a hands-free recording settles, listens again; a failure or cancel turns hands-free off. */
    private fun followHandsFreeSession(s: SessionState) {
        if (handsFree.status != HandsFreeStatus.Recording) return
        when (val dictation = s.dictation) {
            is DictationState.Done ->
                if (s.cleanup != CleanupStatus.Running && !s.releasingMicrophone) handsFree.resumeListening()
            // A recording too short to send is not an error: listen for the next one.
            is DictationState.Failed -> when {
                dictation.failure != DictationFailure.NoSpeech -> handsFree.disarm(failed = true)
                !s.releasingMicrophone -> handsFree.resumeListening()
            }
            DictationState.Idle -> handsFree.disarm()
            else -> Unit
        }
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
        val retention = _state.value.retention
        val service = sync
        if (service == null) {
            historyOwner.remove(id, retention)
            return
        }
        // Recorded first, so iCloud deletes the entry even if the app stops straight after.
        scope.launch {
            service.recordDeletions(listOf(id))
            historyOwner.remove(id, retention)
        }
    }

    /** Clears History; [keepRecordings] keeps the entries that hold a recording. */
    fun clearHistory(keepRecordings: Boolean = false) {
        val retention = _state.value.retention
        val service = sync
        if (service == null) {
            historyOwner.clear(keepRecordings, retention)
            return
        }
        // Only the entries this clears are deleted from iCloud.
        val ids = _state.value.history.filter { !keepRecordings || it.audioPath == null }.map { it.id }
        scope.launch {
            service.recordDeletions(ids)
            historyOwner.clear(keepRecordings, retention)
        }
    }

    /** Opens Apple's sign-in page with [openBrowser], then syncs History with iCloud. */
    fun signInToHistorySync(openBrowser: (String) -> Boolean) {
        val service = sync ?: return
        if (historySignIn?.isActive == true) return
        historySignIn = scope.launch { service.signIn(openBrowser) }
    }

    fun signOutOfHistorySync() {
        val service = sync ?: return
        historySignIn?.cancel()
        historySignIn = null
        pendingHistorySync?.cancel()
        scope.launch { service.signOut() }
    }

    /** Syncs now, for Sync now and when the app comes to the foreground. */
    fun syncHistory() {
        val service = sync ?: return
        pendingHistorySync?.cancel()
        pendingHistorySync = null
        scope.launch { service.sync() }
    }

    /** A local History change; waits briefly so a burst of changes is sent in one pass. */
    private fun requestHistorySync() {
        val service = sync ?: return
        if (!service.status.value.signedIn) return
        pendingHistorySync?.cancel()
        pendingHistorySync = scope.launch {
            delay(HISTORY_SYNC_DELAY_MS)
            service.sync()
        }
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
        if (handsFree.armed) handsFree.disarm(failed = true)
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

    fun setExportCredentials(enabled: Boolean) = updateTransfer { it.copy(exportCredentials = enabled) }

    fun setImportCredentials(enabled: Boolean) = updateTransfer { it.copy(importCredentials = enabled) }

    /**
     * Writes the configuration archive to the stream [open] returns. If the export does not finish,
     * [discard] removes the partly written file so it is never mistaken for a backup.
     */
    fun exportConfiguration(open: () -> OutputStream?, discard: () -> Unit) {
        val transfer = _state.value.transfer
        if (transfer.busy) return
        updateTransfer { it.copy(busy = true, outcome = null, detail = null) }
        scope.launch {
            val history = historyOwner.snapshot(_state.value.retention)
            val ok = withContext(transferIo) {
                val written = try {
                    val output = open() ?: throw IOException("The file could not be created.")
                    output.use {
                        ConfigExporter.export(it, prefs, history, secrets, transfer.exportCredentials, System.currentTimeMillis())
                    }
                    true
                } catch (_: IOException) {
                    false
                } catch (_: SecurityException) {
                    false
                } catch (_: GeneralSecurityException) {
                    false
                } catch (_: ProviderException) {
                    false
                }
                if (!written) discard()
                written
            }
            updateTransfer {
                it.copy(busy = false, outcome = if (ok) TransferOutcome.Exported else TransferOutcome.ExportFailed)
            }
        }
    }

    /** Reads the archive [open] returns and shows what importing it would change; nothing changes yet. */
    fun inspectConfiguration(open: () -> InputStream?) {
        val current = _state.value
        if (current.transfer.busy || current.dictation.isActive) return
        pendingImport = null
        updateTransfer { it.copy(busy = true, preview = null, importCredentials = false, outcome = null, detail = null) }
        scope.launch {
            val history = historyOwner.snapshot(_state.value.retention)
            var detail: String? = null
            val plan = withContext(transferIo) {
                try {
                    val contents = transferFiles.read(open)
                    ConfigImporter.plan(contents, prefs, history, secrets.names(), System.currentTimeMillis())
                } catch (e: ConfigArchiveException) {
                    detail = e.message
                    null
                } catch (_: IOException) {
                    null
                } catch (_: SecurityException) {
                    null
                }
            }
            pendingImport = plan
            updateTransfer {
                it.copy(
                    busy = false,
                    preview = plan?.preview,
                    outcome = if (plan == null) TransferOutcome.Unreadable else null,
                    detail = detail,
                )
            }
        }
    }

    /** Applies the previewed import all or nothing. Refused while dictating, so a session keeps its settings. */
    fun applyConfigurationImport() {
        val plan = pendingImport ?: return
        val current = _state.value
        if (current.transfer.busy || current.dictation.isActive) return
        pendingImport = null
        val includeCredentials = current.transfer.importCredentials
        val previousRetention = prefs.retention
        updateTransfer { it.copy(busy = true) }
        scope.launch {
            val ok = importApplier.applyPlan(plan, includeCredentials)
            withContext(transferIo) { transferFiles.clear() }
            if (ok) reloadAfterImport(previousRetention)
            updateTransfer {
                it.copy(
                    busy = false,
                    preview = null,
                    importCredentials = false,
                    outcome = if (ok) TransferOutcome.Imported else TransferOutcome.ImportFailed,
                    generation = if (ok) it.generation + 1 else it.generation,
                )
            }
        }
    }

    fun dismissConfigurationImport() {
        if (_state.value.transfer.busy) return
        pendingImport = null
        updateTransfer { it.copy(preview = null, importCredentials = false) }
        scope.launch { withContext(transferIo) { transferFiles.clear() } }
    }

    private fun reloadAfterImport(previousRetention: Retention) {
        _state.update {
            it.copy(
                cleanupEnabled = prefs.cleanupEnabled,
                cleanupModel = CloudCatalog.cleanupModel(prefs.cleanupModelId),
                retention = prefs.retention,
                keepAudioOnCancel = prefs.keepAudioOnCancel,
                corrections = prefs.corrections,
                cleanupPrompt = prefs.cleanupPrompt,
                profiles = prefs.profiles,
            )
        }
        selector.reload()
        if (prefs.retention != previousRetention) historyOwner.refresh(prefs.retention, capture::recoverable)
    }

    private fun updateTransfer(change: (ConfigTransferState) -> ConfigTransferState) {
        _state.update { it.copy(transfer = change(it.transfer)) }
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
        followHandsFreeSession(s)
        syncForeground(s)
    }

    /** Shows the service while a session needs it and, between hands-free recordings, while listening. */
    private fun syncForeground(s: SessionState) {
        val phase = foregroundPhase(s) ?: ForegroundPhase.Listening.takeIf { handsFree.armed }
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
        handsFree.disarm()
        interruptions.stop()
        if (foregroundPhase != null) foreground.hide()
        if (ForegroundDictation.listener === foregroundListener) ForegroundDictation.listener = null
        engine.close()
        session.close()
        sounds?.close()
        inputWatch.close()
    }

    companion object {
        private const val HISTORY_SYNC_DELAY_MS = 2_000L

        /** Wires the production collaborators. */
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val application = checkNotNull(this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY])
                create(application)
            }
        }

        private fun create(application: Application): DictationViewModel {
            val prefs = AppPreferences(application)
            val balanceDirectory = loadBalanceDirectory(application)
            val inputs = AndroidAudioInputs(application)
            return DictationViewModel(
                engine = AndroidSpeechEngine(application),
                recorders = { file, onLevel, onLimitReached, onCaptureFailed ->
                    // A saved microphone that is not connected records from the system default, as Settings says.
                    val input = prefs.audioInputId?.let(inputs::route)
                    WavRecorder(file, onLevel, onLimitReached, onCaptureFailed, input = input)
                },
                cloud = CloudClient(),
                secrets = KeystoreSecretStore.create(application),
                prefs = prefs,
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
                audioInputs = inputs,
                balanceDirectory = balanceDirectory,
                balanceClients = ProviderBalanceClients.defaults(balanceDirectory),
                handsFreeMicrophone = AudioRecordMicrophone(),
                historySync = { entries ->
                    AndroidHistorySync.create(application, KeystoreSecretStore.create(application), entries, Dispatchers.IO)
                },
            )
        }

        /** A missing or unreadable asset hides balances rather than stopping the app. */
        private fun loadBalanceDirectory(application: Application): BalanceDirectory = try {
            application.assets.open(BalanceDirectory.ASSET).bufferedReader().use {
                BalanceDirectory.parse(it.readText())
            }
        } catch (e: java.io.IOException) {
            BalanceDirectory.EMPTY
        } catch (e: org.json.JSONException) {
            BalanceDirectory.EMPTY
        } catch (e: IllegalArgumentException) {
            BalanceDirectory.EMPTY
        }
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
