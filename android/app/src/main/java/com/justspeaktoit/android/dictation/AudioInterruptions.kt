package com.justspeaktoit.android.dictation

/** Something outside the app that affects a session's audio while it captures. */
internal enum class InterruptionSignal {
    /** Another app took audio focus for a while (an assistant or another recorder). */
    FocusLostTransient,

    /** Another app took audio focus for good, or focus could not be had at all. */
    FocusLost,

    /** Focus came back after a transient loss. */
    FocusGained,

    /** The phone started ringing or a phone or VoIP call started. */
    CallStarted,

    /** A microphone was connected or disconnected (wired or USB headset, Bluetooth). */
    InputDeviceChanged,
}

/** What a capturing session does about an [InterruptionSignal]. */
internal sealed interface InterruptionAction {
    data object None : InterruptionAction

    /** Stop writing audio but keep the session, until focus returns. */
    data object Pause : InterruptionAction

    data object Resume : InterruptionAction

    /** End capture, keeping what was captured, and tell the user [failure]. */
    data class Stop(val failure: DictationFailure) : InterruptionAction
}

/**
 * Decides what an interruption does to a capturing session. Only a recording (Cloud or Downloaded) asks
 * for audio focus, because the platform recogniser manages its own and cannot pause, so only a
 * recording pauses on a transient loss and resumes on gain. Calls and microphone route changes end any session: the audio
 * after them would be silence or a different microphone, and a session never switches silently.
 */
internal object InterruptionPolicy {
    fun decide(signal: InterruptionSignal, mode: RecognitionMode, paused: Boolean): InterruptionAction =
        when (signal) {
            InterruptionSignal.FocusLostTransient ->
                if (mode.recordsAudio && !paused) InterruptionAction.Pause else InterruptionAction.None
            InterruptionSignal.FocusGained -> if (paused) InterruptionAction.Resume else InterruptionAction.None
            InterruptionSignal.FocusLost -> InterruptionAction.Stop(DictationFailure.AudioFocusLost)
            InterruptionSignal.CallStarted -> InterruptionAction.Stop(DictationFailure.InterruptedByCall)
            InterruptionSignal.InputDeviceChanged -> InterruptionAction.Stop(DictationFailure.AudioDeviceChanged)
        }
}

/**
 * Watches for interruptions while a session captures; `AndroidAudioInterruptions` in production.
 * Signals arrive on the main thread.
 */
internal interface AudioInterruptions {
    /** Starts watching. With [requestFocus] it also holds transient audio focus for Cloud capture. */
    fun start(requestFocus: Boolean, onSignal: (InterruptionSignal) -> Unit)

    /** Stops watching and abandons any focus held. Safe to call when not started. */
    fun stop()
}

internal object NoAudioInterruptions : AudioInterruptions {
    override fun start(requestFocus: Boolean, onSignal: (InterruptionSignal) -> Unit) = Unit

    override fun stop() = Unit
}

/**
 * Keeps [interruptions] watching while a session captures and applies [InterruptionPolicy] to what it
 * reports, for every surface that runs a [DictationSessionController] (the app and the keyboard's live
 * Cloud sessions). Hand it every state the controller publishes; watching starts when capture starts
 * and stops, abandoning audio focus, when capture ends. [session] is read only when a signal arrives.
 */
internal class SessionInterruptionWatch(
    private val interruptions: AudioInterruptions,
    private val session: () -> DictationSessionController,
) {
    private var watching = false

    fun onSessionChanged(s: SessionState) {
        val capturing = s.dictation is DictationState.Starting || s.dictation is DictationState.Listening
        if (capturing == watching) return
        watching = capturing
        if (capturing) {
            interruptions.start(requestFocus = s.dictation.modeOrNull()?.recordsAudio == true, ::onInterruption)
        } else {
            interruptions.stop()
        }
    }

    /** Stops watching when the owner goes away. */
    fun stop() {
        watching = false
        interruptions.stop()
    }

    private fun onInterruption(signal: InterruptionSignal) {
        val session = session()
        if (!session.isCapturing) return
        val mode = session.state.dictation.modeOrNull() ?: return
        when (val action = InterruptionPolicy.decide(signal, mode, session.state.paused)) {
            InterruptionAction.None -> Unit
            InterruptionAction.Pause -> session.pause()
            InterruptionAction.Resume -> session.resume()
            is InterruptionAction.Stop -> session.interrupt(action.failure)
        }
    }
}
