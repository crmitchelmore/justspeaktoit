package com.justspeaktoit.android.dictation

/** What the ongoing dictation notification shows. */
internal enum class ForegroundPhase { Recording, Paused, Finishing }

/**
 * The phase a session needs the foreground service for, or null when it needs none. The service runs
 * from the moment capture starts until the session's audio is transcribed or saved, so neither the
 * recording nor its upload is frozen while another app is in front or the screen is off.
 */
internal fun foregroundPhase(session: SessionState): ForegroundPhase? = when (session.dictation) {
    is DictationState.Starting, is DictationState.Listening ->
        if (session.paused) ForegroundPhase.Paused else ForegroundPhase.Recording
    is DictationState.Finishing -> ForegroundPhase.Finishing
    // A stopped recording that is still being saved.
    else -> if (session.releasingMicrophone) ForegroundPhase.Finishing else null
}

/** Shows the microphone foreground service and its notification; `AndroidForegroundSession` in production. */
internal interface ForegroundSession {
    /**
     * Starts the service or updates its notification. Returns false when Android refused to start it,
     * in which case the session must stop when the app leaves the screen.
     */
    fun show(phase: ForegroundPhase): Boolean

    fun hide()
}

internal object NoForegroundSession : ForegroundSession {
    override fun show(phase: ForegroundPhase) = false

    override fun hide() = Unit
}

/**
 * Connects the foreground service to the session that started it. Both live in the app's process and
 * every call is on the main thread.
 */
internal object ForegroundDictation {
    interface Listener {
        /** The notification's Stop action: finish the session as the Stop button would. */
        fun onStopRequested()

        /** Android would not let the service run in the foreground, so the session is no longer protected. */
        fun onForegroundRefused()
    }

    var listener: Listener? = null
}
