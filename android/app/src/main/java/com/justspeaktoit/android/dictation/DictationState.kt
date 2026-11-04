package com.justspeaktoit.android.dictation

/** Where speech is recognised. The user chooses; a session never switches silently. */
enum class RecognitionMode {
    /** The platform's on-device recogniser (API 31+). Audio stays on the phone. */
    OnDevice,

    /** The default recognition service, which may send audio to its provider. */
    SpeechService,

    /** A bring-your-own-key cloud model. Audio is uploaded to the chosen provider. */
    Cloud,
}

/** Why a session ended without a usable transcript. */
enum class DictationFailure {
    NoSpeech,
    NoMatch,
    Network,
    NetworkTimeout,
    Audio,
    PermissionDenied,
    RecognizerBusy,
    Server,
    Client,
    TooManyRequests,
    LanguageNotSupported,
    LanguageUnavailable,
    LeftApp,
    Unavailable,
    InvalidKey,
    KeyUnavailable,
    Unknown,
}

sealed interface DictationState {
    data object Idle : DictationState

    data class Starting(val mode: RecognitionMode) : DictationState

    data class Listening(val mode: RecognitionMode, val partial: String) : DictationState

    data class Finishing(val mode: RecognitionMode, val partial: String) : DictationState

    data class Done(val mode: RecognitionMode, val transcript: String) : DictationState

    /** [unfinishedText] holds any partial words so they can be recovered, never presented as final. */
    data class Failed(
        val mode: RecognitionMode,
        val failure: DictationFailure,
        val unfinishedText: String,
    ) : DictationState

    val isActive: Boolean
        get() = this is Starting || this is Listening || this is Finishing
}

sealed interface DictationEvent {
    data class Start(val mode: RecognitionMode) : DictationEvent

    data object Ready : DictationEvent

    /** Partial results replace, rather than extend, the current hypothesis. */
    data class Partial(val text: String) : DictationEvent

    data object StopRequested : DictationEvent

    data class Final(val text: String) : DictationEvent

    data class Error(val failure: DictationFailure) : DictationEvent

    data object Cancelled : DictationEvent
}

object DictationReducer {
    fun reduce(state: DictationState, event: DictationEvent): DictationState = when (event) {
        is DictationEvent.Start ->
            if (state.isActive) state else DictationState.Starting(event.mode)

        DictationEvent.Ready ->
            if (state is DictationState.Starting) DictationState.Listening(state.mode, "") else state

        is DictationEvent.Partial -> when (state) {
            is DictationState.Starting -> DictationState.Listening(state.mode, event.text)
            is DictationState.Listening -> state.copy(partial = event.text)
            is DictationState.Finishing -> state.copy(partial = event.text)
            else -> state
        }

        DictationEvent.StopRequested -> when (state) {
            is DictationState.Starting -> DictationState.Finishing(state.mode, "")
            is DictationState.Listening -> DictationState.Finishing(state.mode, state.partial)
            else -> state
        }

        is DictationEvent.Final -> {
            val mode = state.activeMode()
            val text = event.text.trim()
            when {
                mode == null -> state
                text.isEmpty() -> DictationState.Failed(mode, DictationFailure.NoSpeech, state.partialText())
                else -> DictationState.Done(mode, text)
            }
        }

        is DictationEvent.Error -> {
            val mode = state.activeMode()
            if (mode == null) state else DictationState.Failed(mode, event.failure, state.partialText())
        }

        DictationEvent.Cancelled -> if (state.isActive) DictationState.Idle else state
    }

    private fun DictationState.activeMode(): RecognitionMode? = when (this) {
        is DictationState.Starting -> mode
        is DictationState.Listening -> mode
        is DictationState.Finishing -> mode
        else -> null
    }

    private fun DictationState.partialText(): String = when (this) {
        is DictationState.Listening -> partial.trim()
        is DictationState.Finishing -> partial.trim()
        else -> ""
    }
}

/** Maps `SpeechRecognizer.ERROR_*` codes; the values are stable platform constants. */
object RecognizerErrors {
    @Suppress("MagicNumber")
    fun failureFor(code: Int): DictationFailure = when (code) {
        1 -> DictationFailure.NetworkTimeout
        2 -> DictationFailure.Network
        3 -> DictationFailure.Audio
        4, 11 -> DictationFailure.Server
        5 -> DictationFailure.Client
        6 -> DictationFailure.NoSpeech
        7 -> DictationFailure.NoMatch
        8 -> DictationFailure.RecognizerBusy
        9 -> DictationFailure.PermissionDenied
        10 -> DictationFailure.TooManyRequests
        12 -> DictationFailure.LanguageNotSupported
        13 -> DictationFailure.LanguageUnavailable
        else -> DictationFailure.Unknown
    }
}
