package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.cloud.SharedAudio
import com.justspeaktoit.android.cloud.WavFormat
import com.justspeaktoit.android.cloud.live.LiveOutcome
import com.justspeaktoit.android.cloud.live.LiveTranscriptListener
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.resources.SystemResourceToken
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.io.IOException

/** One dictation session's state, as the screen shows it. */
internal data class SessionState(
    val dictation: DictationState = DictationState.Idle,
    val cleanup: CleanupStatus = CleanupStatus.None,
    /** The transcript before an applied cleanup, so the user can restore it. */
    val originalTranscript: String? = null,
    /** True until a cancelled Cloud recording has released the microphone. */
    val releasingMicrophone: Boolean = false,
)

/** Settings a session reads when it needs them, so a change during the session applies to its end. */
internal interface SessionSettings {
    val retention: Retention
    val keepAudioOnCancel: Boolean

    /** The model for an optional cleanup, or null when cleanup is off or its provider has no key. */
    val cleanupModel: CleanupModel?

    /** Personal corrections applied to every final transcript, and sent to cloud models as vocabulary. */
    val corrections: List<CorrectionRule> get() = emptyList()
}

/**
 * Owns the dictation session lifecycle: start, stop, finish, cancel and leaving the app, for the
 * platform recogniser and for Cloud capture and upload, then the optional cleanup. It holds the
 * microphone in [resources] while a session captures and until a Cloud recorder has really stopped;
 * provider requests are held by [CloudCapture.call] while they run. Every ended session is recorded in
 * [history]. Call from the main thread of [scope]; each change is handed to [publish].
 *
 * A live model also streams the recording to its provider through [liveSessions], showing partial
 * text while the user speaks. Its failure ends the session with that text kept as unfinished; no
 * batch upload is substituted for it.
 */
internal class DictationSessionController(
    private val engine: SpeechEngine,
    private val capture: CloudCapture,
    private val requests: SessionRequests,
    private val history: DictationHistory,
    private val resources: SystemResourceRegistry,
    private val scope: CoroutineScope,
    private val cacheDir: File,
    private val settings: SessionSettings,
    private val publish: (SessionState) -> Unit,
    private val liveSessions: LiveSessions = LiveSessions.Default,
) {
    var state = SessionState()
        private set

    // Kept separate so microphone level updates only recompose the level indicator.
    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level.asStateFlow()

    /** The upload or cleanup under way; cancelling it drops its result. */
    private var work: Job? = null
    private var microphoneHold: SystemResourceToken? = null

    // The model is fixed when the session starts, so later Settings changes cannot relabel it.
    private var sessionModelId: String? = null

    /** The Cloud session's plan, so its upload uses the model and language the recording started with. */
    private var cloudPlan: SessionPlan.Cloud? = null

    /** The live session streaming the current Cloud recording, when its model is live. */
    private var live: LiveRun? = null

    val isCapturing: Boolean
        get() = state.dictation is DictationState.Starting || state.dictation is DictationState.Listening

    fun start(plan: SessionPlan) {
        change { it.copy(cleanup = CleanupStatus.None, originalTranscript = null) }
        cloudPlan = plan as? SessionPlan.Cloud
        sessionModelId = cloudPlan?.model?.catalogId
        dispatch(DictationEvent.Start(plan.mode))
        when (plan) {
            is SessionPlan.Cloud -> startCloud()
            is SessionPlan.Recognizer ->
                engine.start(plan.mode, plan.languageTag, onEvent = ::onEngineEvent, onLevel = { _level.value = it })
        }
    }

    fun stop() {
        if (!isCapturing) return
        val mode = state.dictation.modeOrNull()
        dispatch(DictationEvent.StopRequested)
        if (mode == RecognitionMode.Cloud) finishCloud() else engine.stop()
    }

    fun cancel() {
        // Only a user cancel of a Cloud capture keeps audio: other modes never produce a file.
        val keep = settings.keepAudioOnCancel && isCapturing &&
            state.dictation.modeOrNull() == RecognitionMode.Cloud && capture.current != null
        engine.cancel()
        work?.cancel()
        cancelLive()
        if (keep) keepCancelledRecording() else discardRecording()
        change { it.copy(cleanup = if (it.cleanup == CleanupStatus.Running) CleanupStatus.None else it.cleanup) }
        dispatch(DictationEvent.Cancelled)
    }

    /**
     * Android does not let a foreground-only app keep the microphone once it leaves the screen, so
     * capture ends as a failure. Work that no longer needs the microphone (an upload) continues.
     */
    fun leaveApp() {
        if (!isCapturing) return
        engine.cancel()
        cancelLive()
        discardRecording()
        dispatch(DictationEvent.Error(DictationFailure.LeftApp))
    }

    /** Stops an optional cleanup without a result, keeping the transcript it would have replaced. */
    fun cancelCleanup() {
        if (state.cleanup != CleanupStatus.Running) return
        work?.cancel()
        change { it.copy(cleanup = CleanupStatus.None) }
    }

    /** Ends a shared-audio session at once because its audio cannot be uploaded. */
    fun rejectSharedAudio(model: CloudModel) {
        sessionModelId = model.catalogId
        dispatch(DictationEvent.Start(RecognitionMode.Cloud))
        dispatch(DictationEvent.Error(DictationFailure.UnsupportedAudio))
    }

    /** Uploads audio another app shared; [copyIn] copies it into the given private file. */
    fun transcribeSharedAudio(
        model: CloudModel,
        languageTag: String,
        copyIn: suspend (File) -> SharedAudio.Format,
    ) {
        if (state.dictation.isActive || state.cleanup == CleanupStatus.Running) return
        change { it.copy(cleanup = CleanupStatus.None, originalTranscript = null) }
        sessionModelId = model.catalogId
        dispatch(DictationEvent.Start(RecognitionMode.Cloud))
        dispatch(DictationEvent.StopRequested)
        work = scope.launch {
            val file = File(cacheDir, "shared-${System.nanoTime()}")
            val event = try {
                requests.transcribe(model, file, languageTag, DictationFailure.MissingKey, vocabulary()) {
                    copyIn(file)
                }
            } catch (e: RequestReleasedException) {
                DictationEvent.Cancelled
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

    fun clearResult() {
        if (state.dictation.isActive || state.cleanup == CleanupStatus.Running) return
        change { it.copy(dictation = DictationState.Idle, cleanup = CleanupStatus.None, originalTranscript = null) }
    }

    fun showOriginal() {
        val original = state.originalTranscript ?: return
        val done = state.dictation as? DictationState.Done ?: return
        history.replaceSessionText(original, cleanedUp = false, settings.retention)
        change {
            it.copy(dictation = done.copy(transcript = original), cleanup = CleanupStatus.None, originalTranscript = null)
        }
    }

    /** Ends the session's holds when its owner goes away; a recording still owned is retired off this thread. */
    fun close() {
        cancelLive()
        microphoneHold?.end()
        microphoneHold = null
        capture.close()
    }

    private fun startCloud() {
        val run = cloudPlan?.takeIf { it.model.live != null }?.let(::startLive)
        val started = capture.start(
            onLevel = { _level.value = it },
            onLimitReached = { rec -> scope.launch { if (capture.owns(rec)) stop() } },
            onCaptureFailed = { rec -> scope.launch { if (capture.owns(rec)) failCapture() } },
            onPcm = run?.let { it.client::append },
        )
        if (!started) cancelLive()
        dispatch(if (started) DictationEvent.Ready else DictationEvent.Error(DictationFailure.Audio))
        if (started && run != null) connectLive(run)
    }

    private fun startLive(plan: SessionPlan.Cloud): LiveRun {
        val run = LiveRun(plan.model)
        val listener = object : LiveTranscriptListener {
            override fun onPartial(text: String) {
                scope.launch { if (live === run && state.dictation.isActive) dispatch(DictationEvent.Partial(text)) }
            }

            override fun onEnd(outcome: LiveOutcome) {
                run.outcome.complete(outcome)
                scope.launch { if (live === run && isCapturing && outcome is LiveOutcome.Failed) failLive(outcome) }
            }
        }
        run.client = liveSessions.create(plan.model, plan.languageTag, settings.corrections.map { it.writeAs }, listener)
        live = run
        return run
    }

    /** Reads the key off the main thread, then opens the stream; audio captured meanwhile is held. */
    private fun connectLive(run: LiveRun) {
        scope.launch {
            val (key, failure) = requests.liveKey(run.model.provider, DictationFailure.MissingKey)
            if (live !== run) return@launch
            if (key != null) {
                run.client.connect(key)
                return@launch
            }
            val outcome = LiveOutcome.Failed(failure ?: DictationFailure.MissingKey, "")
            run.client.cancel()
            if (isCapturing) {
                failLive(outcome)
            } else {
                // A finish already waiting on the outcome ends with it.
                run.outcome.complete(outcome)
            }
        }
    }

    /** The stream failed while recording: stop, keeping what was heard as unfinished text. */
    private fun failLive(outcome: LiveOutcome.Failed) {
        val run = live ?: return
        cancelLive()
        requests.liveFailed(run.model.provider, outcome.failure)
        discardRecording()
        if (outcome.recoveredText.isNotBlank()) dispatch(DictationEvent.Partial(outcome.recoveredText))
        dispatch(DictationEvent.Error(outcome.failure))
    }

    private fun cancelLive() {
        live?.client?.cancel()
        live = null
    }

    private fun failCapture() {
        cancelLive()
        discardRecording()
        dispatch(DictationEvent.Error(DictationFailure.Audio))
    }

    private fun finishCloud() {
        val rec = capture.current ?: return
        val plan = cloudPlan ?: return
        live?.let { return finishLive(rec, it) }
        val file = rec.file
        val modelId = sessionModelId
        work = scope.launch {
            var kept = false
            val event = try {
                // The recorder stays owned (and releasable by close) until stop() has finished.
                val bytes = capture.stop(rec)
                reconcileMicrophoneHold()
                when {
                    bytes < 0 -> DictationEvent.Error(DictationFailure.Audio)
                    bytes < MIN_AUDIO_BYTES -> DictationEvent.Error(DictationFailure.NoSpeech)
                    else -> requests.transcribe(
                        plan.model,
                        file,
                        plan.languageTag,
                        DictationFailure.InvalidKey,
                        vocabulary(),
                    )
                }
            } catch (e: RequestReleasedException) {
                // Releasing the upload is a cancel, so honour "Keep audio when a recording is cancelled".
                if (settings.keepAudioOnCancel) {
                    kept = true
                    history.keepRecording(file, modelId, settings.retention)
                }
                DictationEvent.Cancelled
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

    /**
     * Stops the recorder, so every captured chunk has been appended, then asks the provider to
     * finalise. The client's own deadline bounds the wait; the recording is only a local copy.
     */
    private fun finishLive(rec: CloudCapture.Recording, run: LiveRun) {
        work = scope.launch {
            val event = try {
                val bytes = capture.stop(rec)
                reconcileMicrophoneHold()
                if (bytes < 0) {
                    cancelLive()
                    DictationEvent.Error(DictationFailure.Audio)
                } else {
                    run.client.finish()
                    when (val outcome = run.outcome.await()) {
                        is LiveOutcome.Completed -> DictationEvent.Final(outcome.text)
                        is LiveOutcome.Failed -> {
                            requests.liveFailed(run.model.provider, outcome.failure)
                            if (live === run && outcome.recoveredText.isNotBlank()) {
                                dispatch(DictationEvent.Partial(outcome.recoveredText))
                            }
                            DictationEvent.Error(outcome.failure)
                        }
                    }
                }
            } finally {
                if (live === run) live = null
                capture.release(rec)
                reconcileMicrophoneHold()
                capture.delete(rec.file)
            }
            ensureActive()
            onEngineEvent(event)
        }
    }

    /** Stops capture without a result. Ownership is kept until the recorder has really stopped. */
    private fun discardRecording() {
        val rec = capture.current ?: return
        change { it.copy(releasingMicrophone = true) }
        scope.launch {
            capture.discard(rec)
            reconcileMicrophoneHold()
            change { it.copy(releasingMicrophone = false) }
        }
    }

    /** Stops capture and moves a usable recording into History as a cancelled entry. */
    private fun keepCancelledRecording() {
        val rec = capture.current ?: return
        val file = rec.file
        val modelId = sessionModelId
        val retention = settings.retention
        change { it.copy(releasingMicrophone = true) }
        scope.launch {
            val bytes = capture.stop(rec)
            reconcileMicrophoneHold()
            change { it.copy(releasingMicrophone = false) }
            if (bytes < MIN_AUDIO_BYTES) {
                // Too short to contain a word, so there is nothing worth transcribing later.
                capture.delete(file)
                return@launch
            }
            history.keepRecording(file, modelId, retention)
        }
    }

    /** The microphone is held while a session captures, and until a Cloud recorder has really stopped. */
    private fun reconcileMicrophoneHold() {
        val dictation = state.dictation
        if (dictation.holdsMicrophone || capture.current != null) {
            if (microphoneHold != null) return
            microphoneHold = resources.acquire(
                kind = SystemResourceKind.Microphone,
                title = "Dictation recording",
                reason = when (dictation.modeOrNull()) {
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

    private fun vocabulary(): String? = PersonalCorrections.vocabularyPrompt(settings.corrections)

    private fun onEngineEvent(received: DictationEvent) {
        // Corrected before the reducer sees it, so History, cleanup and the screen all get the same text.
        val event = if (received is DictationEvent.Final) {
            DictationEvent.Final(PersonalCorrections.apply(received.text, settings.corrections))
        } else {
            received
        }
        dispatch(event)
        val done = state.dictation as? DictationState.Done ?: return
        if (event !is DictationEvent.Final) return
        settings.cleanupModel?.let { runCleanup(done, it) }
    }

    private fun runCleanup(done: DictationState.Done, model: CleanupModel) {
        change { it.copy(cleanup = CleanupStatus.Running) }
        work = scope.launch {
            // Cleanup can restore a misheard word, so corrections run again on its output.
            val outcome = when (val cleaned = requests.cleanup(model, done.transcript)) {
                is CleanupOutcome.Applied ->
                    CleanupOutcome.Applied(PersonalCorrections.apply(cleaned.text, settings.corrections))
                else -> cleaned
            }
            if (state.dictation != done) return@launch
            change {
                when (outcome) {
                    CleanupOutcome.Released -> it.copy(cleanup = CleanupStatus.None)
                    CleanupOutcome.Failed -> it.copy(cleanup = CleanupStatus.Failed)
                    is CleanupOutcome.Applied -> it.copy(
                        dictation = done.copy(transcript = outcome.text),
                        cleanup = CleanupStatus.Applied,
                        originalTranscript = done.transcript,
                    )
                }
            }
            if (outcome is CleanupOutcome.Applied) {
                history.replaceSessionText(outcome.text, cleanedUp = true, settings.retention)
            }
        }
    }

    private fun dispatch(event: DictationEvent) {
        val before = state.dictation
        change { it.copy(dictation = DictationReducer.reduce(it.dictation, event)) }
        val after = state.dictation
        if (!after.isActive) _level.value = 0f
        reconcileMicrophoneHold()
        if (!before.isActive || after.isActive) return
        // A session just ended: record it now, so it survives even if optional cleanup never finishes.
        history.recordSession(after, sessionModelId, settings.retention)
    }

    private fun change(transform: (SessionState) -> SessionState) {
        state = transform(state)
        publish(state)
    }

    private companion object {
        /** About a quarter of a second; shorter recordings cannot contain a word. */
        const val MIN_AUDIO_BYTES = WavFormat.BYTES_PER_SECOND / 4
    }
}

internal fun DictationState.modeOrNull(): RecognitionMode? = when (this) {
    is DictationState.Starting -> mode
    is DictationState.Listening -> mode
    is DictationState.Finishing -> mode
    is DictationState.Done -> mode
    is DictationState.Failed -> mode
    DictationState.Idle -> null
}
