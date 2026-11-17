package com.justspeaktoit.android.ime

import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.dictation.AudioInterruptions
import com.justspeaktoit.android.dictation.CloudCapture
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.DictationSessionController
import com.justspeaktoit.android.dictation.DictationState
import com.justspeaktoit.android.dictation.DownloadedTranscription
import com.justspeaktoit.android.dictation.LiveSessions
import com.justspeaktoit.android.dictation.NoAudioInterruptions
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.dictation.SessionHistory
import com.justspeaktoit.android.dictation.SessionInterruptionWatch
import com.justspeaktoit.android.dictation.SessionPlan
import com.justspeaktoit.android.dictation.SessionRequests
import com.justspeaktoit.android.dictation.SessionSettings
import com.justspeaktoit.android.dictation.SessionState
import com.justspeaktoit.android.dictation.SilenceSettings
import com.justspeaktoit.android.dictation.SpeechEngine
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

/**
 * The keyboard's live Cloud dictation (#1668). It runs the app's own [DictationSessionController] live
 * path, so the keyboard streams through the same `LiveTranscription` clients, reads the provider key in
 * process and applies personal corrections exactly as the app does. Nothing is saved to History and no
 * cleanup runs. Finishing is bounded at [finishTimeoutMs], like the keyboard's recognisers: a stream that
 * has not settled by then fails with [DictationFailure.NetworkTimeout], and no other route is tried.
 * While it captures, [interruptions] is watched exactly as in the app: a transient loss of audio focus
 * pauses it ([isPaused]), and a call, a lasting focus loss or a headset change ends it as a failure.
 *
 * It also records for a downloaded Whisper model ([startLocal], #1650) through the same controller, when
 * the keyboard's estimate says the model finishes within the bound ([KeyboardLocalModels]); the
 * recording itself is capped by the caller's recorder, and a run past [finishTimeoutMs] fails visibly
 * with what was heard, as a slow stream does.
 *
 * Call from the main thread of [scope]; each change of the session's state is handed to [onState].
 */
internal class KeyboardLiveDictation(
    engine: SpeechEngine,
    capture: CloudCapture,
    requests: SessionRequests,
    resources: SystemResourceRegistry,
    private val scope: CoroutineScope,
    cacheDir: File,
    corrections: () -> List<CorrectionRule>,
    silence: () -> SilenceSettings,
    private val onState: (DictationState) -> Unit,
    liveSessions: LiveSessions = LiveSessions.Default,
    interruptions: AudioInterruptions = NoAudioInterruptions,
    private val finishTimeoutMs: Long = KeyboardPolicy.FINISH_TIMEOUT_MS,
    downloaded: DownloadedTranscription = DownloadedTranscription.Unavailable,
) {
    /** True from [start] until the session ends, so a late update from an abandoned one is ignored. */
    private var running = false

    /** Set once this session's state turns active; the controller publishes its previous state first. */
    private var begun = false
    private var finishWatch: Job? = null

    private val interruptionWatch = SessionInterruptionWatch(interruptions) { controller }

    private val controller = DictationSessionController(
        engine = engine,
        capture = capture,
        requests = requests,
        history = SessionHistory.None,
        resources = resources,
        scope = scope,
        cacheDir = cacheDir,
        settings = object : SessionSettings {
            override val retention: Retention get() = Retention.Off
            override val keepAudioOnCancel: Boolean get() = false
            override val cleanupModel get() = null
            override val corrections: List<CorrectionRule> get() = corrections()
            override val silence: SilenceSettings get() = silence()
        },
        publish = ::onSession,
        liveSessions = liveSessions,
        microphoneOwner = "DictationKeyboardService",
        downloaded = downloaded,
    )

    val isRunning: Boolean get() = running

    /** True while another app briefly holds audio focus: audio is not being sent. */
    val isPaused: Boolean get() = running && controller.state.paused

    /** Starts streaming to [model], which must be a live model; a batch model is never uploaded instead. */
    fun start(model: CloudModel, languageTag: String) {
        require(model.live != null) { "${model.catalogId} is not a live model" }
        finishWatch?.cancel()
        running = true
        begun = false
        controller.start(SessionPlan.Cloud(model, languageTag))
    }

    /** Records for the downloaded Whisper model [modelId], which transcribes once recording stops. */
    fun startLocal(modelId: String, languageTag: String) {
        finishWatch?.cancel()
        running = true
        begun = false
        controller.start(SessionPlan.Local(modelId, languageTag))
    }

    /**
     * Asks for the final text; the wait is bounded at [finishTimeoutMs] from when the session starts
     * finishing, whether this stopped it or its recording limit did.
     */
    fun stop() {
        if (!running || !controller.isCapturing) return
        controller.stop()
    }

    fun cancel() {
        if (!running) return
        running = false
        finishWatch?.cancel()
        controller.cancel()
    }

    /** Ends the session and releases the microphone when the keyboard goes away. */
    fun close() {
        cancel()
        interruptionWatch.stop()
        controller.close()
    }

    private fun onSession(session: SessionState) {
        // Before the running check, so watching always ends with capture, however the session ended.
        interruptionWatch.onSessionChanged(session)
        if (!running) return
        val dictation = session.dictation
        if (dictation.isActive) begun = true
        if (!begun) return
        if (dictation is DictationState.Finishing && finishWatch?.isActive != true) {
            finishWatch = scope.launch {
                delay(finishTimeoutMs)
                timeOut()
            }
        }
        // Ended, including a release from Settings > System resources, which cancels the controller directly.
        if (!dictation.isActive) {
            running = false
            finishWatch?.cancel()
        }
        onState(dictation)
    }

    private fun timeOut() {
        if (!running) return
        val finishing = controller.state.dictation as? DictationState.Finishing
        val mode = finishing?.mode ?: RecognitionMode.Cloud
        running = false
        controller.cancel()
        onState(DictationState.Failed(mode, DictationFailure.NetworkTimeout, finishing?.partial.orEmpty()))
    }
}
