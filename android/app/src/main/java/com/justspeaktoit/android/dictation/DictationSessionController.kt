package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CleanupPolicy
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.RecordingRecovery
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.cloud.SharedAudio
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.resources.SystemResourceToken
import com.justspeaktoit.android.settings.RecordingCue
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
    /** A Cloud capture paused while another app briefly holds audio focus. */
    val paused: Boolean = false,
)

/** Settings a session reads when it needs them, so a change during the session applies to its end. */
internal interface SessionSettings {
    val retention: Retention
    val keepAudioOnCancel: Boolean

    /** The model for an optional cleanup, or null when cleanup is off or its provider has no key. */
    val cleanupModel: CleanupModel?

    /** The user's base cleanup prompt for this session, or null for the built-in one. */
    val cleanupPrompt: String? get() = null

    /** Personal corrections applied to every final transcript, and sent to cloud models as vocabulary. */
    val corrections: List<CorrectionRule> get() = emptyList()
}

/** Plays a recording cue when sounds are on; returns how long it lasts in milliseconds, or 0 if none plays. */
internal fun interface RecordingCues {
    fun play(cue: RecordingCue): Long

    companion object {
        val Silent = RecordingCues { 0L }
    }
}

/**
 * Owns the dictation session lifecycle: start, stop, finish, cancel and leaving the app, for the
 * platform recogniser and for Cloud capture and upload, then the optional cleanup. It holds the
 * microphone in [resources] while a session captures and until a Cloud recorder has really stopped;
 * provider requests are held by [CloudCapture.call] while they run. Every ended session is recorded in
 * [history]. Call from the main thread of [scope]; each change is handed to [publish].
 *
 * [cues] play Start once capture is listening and Stop once it has ended normally, never on cancel or
 * failure, matching the desktop apps. Cloud capture records silence over the Start cue.
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
    private val cues: RecordingCues = RecordingCues.Silent,
    private val publish: (SessionState) -> Unit,
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
    var sessionModelId: String? = null
        private set

    /** The Cloud session's plan, so its upload uses the model and language the recording started with. */
    private var cloudPlan: SessionPlan.Cloud? = null

    /** Set by [close]: work cut short after it keeps its recording for recovery instead of deleting it. */
    private var closed = false

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
        if (mode == RecognitionMode.Cloud) {
            finishCloud()
        } else {
            engine.stop()
            cues.play(RecordingCue.Stop)
        }
    }

    fun cancel() {
        // Only a user cancel of a Cloud capture keeps audio: other modes never produce a file.
        val keep = settings.keepAudioOnCancel && isCapturing &&
            state.dictation.modeOrNull() == RecognitionMode.Cloud && capture.current != null
        engine.cancel()
        work?.cancel()
        if (keep) keepCancelledRecording() else discardRecording()
        change { it.copy(cleanup = if (it.cleanup == CleanupStatus.Running) CleanupStatus.None else it.cleanup) }
        dispatch(DictationEvent.Cancelled)
    }

    /**
     * Without a foreground service Android does not let the app keep the microphone once it leaves
     * the screen, so capture ends as a failure. Work that no longer needs the microphone (an upload)
     * continues.
     */
    fun leaveApp() = interrupt(DictationFailure.LeftApp)

    /**
     * Ends capture because something outside the app took the microphone (a call, another app's audio
     * or a headset change). Nothing is lost: unfinished recogniser text is recorded with the failure,
     * and a Cloud recording is saved beside it in History, ready to transcribe.
     */
    fun interrupt(failure: DictationFailure) {
        if (!isCapturing) return
        val rec = if (state.dictation.modeOrNull() == RecognitionMode.Cloud) capture.current else null
        engine.cancel()
        dispatch(DictationEvent.Error(failure))
        if (rec != null) saveInterruptedRecording(rec, history.latestSession)
    }

    /** Stops writing Cloud audio while another app briefly has audio focus; the microphone stays held. */
    fun pause() {
        if (!isCapturing || state.paused || state.dictation.modeOrNull() != RecognitionMode.Cloud) return
        val rec = capture.current ?: return
        rec.recorder.setPaused(true)
        change { it.copy(paused = true) }
    }

    fun resume() {
        if (!state.paused) return
        capture.current?.recorder?.setPaused(false)
        change { it.copy(paused = false) }
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
        closed = true
        microphoneHold?.end()
        microphoneHold = null
        capture.close()
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
        val plan = cloudPlan ?: return
        val file = rec.file
        val modelId = sessionModelId
        work = scope.launch {
            var kept = false
            var settled = false
            val event = try {
                // The recorder stays owned (and releasable by close) until stop() has finished.
                val bytes = capture.stop(rec)
                reconcileMicrophoneHold()
                // Played once the microphone has stopped, so the cue is never in the upload.
                if (bytes >= 0 && state.dictation is DictationState.Finishing) cues.play(RecordingCue.Stop)
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
                }.also { settled = true }
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
                when {
                    kept -> Unit
                    // The screen went away mid-upload: keep the audio for the next History load.
                    closed && !settled -> capture.abandon(file)
                    else -> capture.delete(file)
                }
            }
            // A cancelled upload must not deliver a late result into a newer session.
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
            var handed = false
            try {
                val bytes = capture.stop(rec)
                reconcileMicrophoneHold()
                change { it.copy(releasingMicrophone = false) }
                handed = true
                if (bytes < MIN_AUDIO_BYTES) {
                    // Too short to contain a word, so there is nothing worth transcribing later.
                    capture.delete(file)
                    return@launch
                }
                history.keepRecording(file, modelId, retention)
            } finally {
                if (!handed) capture.abandon(file)
            }
        }
    }

    /** Stops an interrupted recording and attaches it to the session's failed History [entry]. */
    private fun saveInterruptedRecording(rec: CloudCapture.Recording, entry: HistoryEntry?) {
        val retention = settings.retention
        change { it.copy(releasingMicrophone = true) }
        scope.launch {
            var handed = false
            try {
                // A capture failure still leaves the audio written so far; attaching repairs its header.
                capture.stop(rec)
                reconcileMicrophoneHold()
                change { it.copy(releasingMicrophone = false) }
                history.attachAudio(rec.file, entry, retention)
                handed = true
            } finally {
                // The screen went away first, so the next History load recovers it instead.
                if (!handed) capture.abandon(rec.file)
            }
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
            val systemPrompt = CleanupPolicy.systemPrompt(settings.cleanupPrompt)
            val outcome = when (val cleaned = requests.cleanup(model, done.transcript, systemPrompt)) {
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
        change {
            val dictation = DictationReducer.reduce(it.dictation, event)
            val capturing = dictation is DictationState.Starting || dictation is DictationState.Listening
            if (!capturing) capture.current?.recorder?.setPaused(false)
            it.copy(dictation = dictation, paused = it.paused && capturing)
        }
        val after = state.dictation
        playCue(before, after, event)
        if (!after.isActive) _level.value = 0f
        reconcileMicrophoneHold()
        if (!before.isActive || after.isActive) return
        // A session just ended: record it now, so it survives even if optional cleanup never finishes.
        history.recordSession(after, sessionModelId, settings.retention)
    }

    private fun playCue(before: DictationState, after: DictationState, event: DictationEvent) {
        if (before is DictationState.Starting && after is DictationState.Listening) {
            val millis = cues.play(RecordingCue.Start)
            if (millis > 0) capture.current?.recorder?.mute(millis)
        } else if (before is DictationState.Listening && event is DictationEvent.Final) {
            // The recogniser ended the capture itself, after a pause.
            cues.play(RecordingCue.Stop)
        }
    }

    private fun change(transform: (SessionState) -> SessionState) {
        state = transform(state)
        publish(state)
    }

    private companion object {
        const val MIN_AUDIO_BYTES = RecordingRecovery.MIN_AUDIO_BYTES
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
