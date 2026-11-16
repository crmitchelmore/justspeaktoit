package com.justspeaktoit.android.readaloud

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.coroutines.CoroutineContext

/** The voice read aloud uses, saved as `readAloudVoice`. */
sealed interface VoiceSelection {
    val encoded: String

    /** The phone's text-to-speech engine, with one of its voices or its default. */
    data class System(val voiceName: String? = null) : VoiceSelection {
        override val encoded: String get() = voiceName?.let { "$SYSTEM_PREFIX$it" } ?: SYSTEM
    }

    /** A cloud voice of the exported catalogue, by its `modelID|id` key. */
    data class Cloud(val key: String) : VoiceSelection {
        override val encoded: String get() = "$CLOUD_PREFIX$key"
    }

    companion object {
        const val SYSTEM = "system"
        private const val SYSTEM_PREFIX = "system:"
        private const val CLOUD_PREFIX = "cloud:"

        fun parse(value: String?): VoiceSelection = when {
            value == null -> System()
            value.startsWith(SYSTEM_PREFIX) -> System(value.removePrefix(SYSTEM_PREFIX).ifBlank { null })
            value.startsWith(CLOUD_PREFIX) && value.length > CLOUD_PREFIX.length -> Cloud(value.removePrefix(CLOUD_PREFIX))
            else -> System()
        }
    }
}

/** Speaks text with one voice. */
interface ReadAloudEngine {
    /**
     * Speaks [text], returning once it has all been heard and calling [onAudible] when sound starts.
     * [language] is the text's base language code when it is known, otherwise null. Throws
     * [ReadAloudException]; cancelling the caller stops the sound at once.
     */
    suspend fun play(text: String, language: String?, onAudible: () -> Unit)

    fun pause()

    fun resume()
}

/** What read aloud does when another app takes the audio focus. */
enum class FocusChange { Lost, LostTransient, Gained }

interface ReadAloudFocus {
    /** False when the focus is refused, for example during a call. */
    fun request(onChange: (FocusChange) -> Unit): Boolean

    fun abandon()
}

enum class ReadAloudPhase { Idle, Preparing, Speaking, Paused }

data class ReadAloudState(val phase: ReadAloudPhase = ReadAloudPhase.Idle, val failure: ReadAloudFailure? = null) {
    val active: Boolean get() = phase != ReadAloudPhase.Idle
}

/**
 * The language a cloud voice is asked to speak, as SpeakCore's `VoiceOutputLanguageCatalog` resolves
 * it: a known language first, then the language detected in the text, then the phone's.
 */
object ReadAloudLanguage {
    private val automatic = setOf("auto", "automatic", "und")

    /** The base code of a language identifier such as `es-MX`, or null when it names none. */
    fun base(identifier: String?): String? {
        val code = identifier?.trim()?.lowercase(Locale.ROOT)?.split('_', '-')?.first().orEmpty()
        return code.takeUnless { it.isEmpty() || it in automatic }
    }

    fun resolve(known: String?, detected: String?, device: String?): String =
        base(known) ?: base(detected) ?: base(device) ?: DEFAULT

    private const val DEFAULT = "en"
}

/**
 * Reads text aloud with the chosen voice after applying the pronunciation dictionary. A failure
 * stops the reading and is reported in [state]; it never moves to another voice or provider. The
 * dictionary runs on [work], never on the caller's thread.
 */
class ReadAloudController(
    private val scope: CoroutineScope,
    private val engines: (VoiceSelection) -> ReadAloudEngine,
    private val focus: ReadAloudFocus,
    private val work: CoroutineContext = Dispatchers.Default,
) {
    private val mutableState = MutableStateFlow(ReadAloudState())
    val state: StateFlow<ReadAloudState> = mutableState.asStateFlow()

    private var job: Job? = null
    private var engine: ReadAloudEngine? = null
    private var pausedForFocus = false

    /** Reads [text]; [language] is the language it was dictated in when known, such as `es-ES`. */
    fun speak(
        text: String,
        selection: VoiceSelection,
        pronunciations: List<PronunciationEntry>,
        language: String? = null,
    ) {
        stop()
        if (text.isBlank()) return
        val chosen = try {
            engines(selection)
        } catch (error: ReadAloudException) {
            mutableState.value = ReadAloudState(failure = error.failure)
            return
        } catch (_: Exception) {
            // A key store or engine fault before playback; shown rather than escaping the tap.
            mutableState.value = ReadAloudState(failure = ReadAloudFailure.PlaybackFailed)
            return
        }
        if (!focus.request(::onFocus)) {
            mutableState.value = ReadAloudState(failure = ReadAloudFailure.AudioBusy)
            return
        }
        engine = chosen
        mutableState.value = ReadAloudState(ReadAloudPhase.Preparing)
        lateinit var reading: Job
        reading = scope.launch {
            val failure = try {
                // A user's regular expression can be slow, so it never runs on the tapping thread.
                val spoken = withContext(work) {
                    PronunciationDictionary.apply(text, pronunciations, active = { isActive }).trim()
                }
                if (spoken.isNotEmpty()) {
                    chosen.play(spoken, ReadAloudLanguage.base(language)) {
                        mutableState.update {
                            if (it.phase == ReadAloudPhase.Preparing) it.copy(phase = ReadAloudPhase.Speaking) else it
                        }
                    }
                }
                null
            } catch (error: ReadAloudException) {
                error.failure
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // An engine fault that is not a provider answer; still visible, never a silent stop.
                ReadAloudFailure.PlaybackFailed
            }
            if (job === reading) finish(failure)
        }
        job = reading
    }

    fun pause() {
        val phase = state.value.phase
        if (phase != ReadAloudPhase.Preparing && phase != ReadAloudPhase.Speaking) return
        engine?.pause()
        mutableState.update { it.copy(phase = ReadAloudPhase.Paused) }
    }

    fun resume() {
        if (state.value.phase != ReadAloudPhase.Paused) return
        pausedForFocus = false
        if (!focus.request(::onFocus)) {
            mutableState.update { it.copy(failure = ReadAloudFailure.AudioBusy) }
            return
        }
        engine?.resume()
        mutableState.update { it.copy(phase = ReadAloudPhase.Speaking) }
    }

    fun stop() {
        val running = job ?: return
        job = null
        running.cancel()
        finish(null)
    }

    /** Clears a failure once it has been shown. */
    fun dismissFailure() = mutableState.update { it.copy(failure = null) }

    private fun finish(failure: ReadAloudFailure?) {
        job = null
        engine = null
        pausedForFocus = false
        focus.abandon()
        mutableState.value = ReadAloudState(failure = failure)
    }

    private fun onFocus(change: FocusChange) {
        when (change) {
            FocusChange.Lost -> stop()
            FocusChange.LostTransient -> if (state.value.phase != ReadAloudPhase.Paused) {
                pause()
                pausedForFocus = state.value.phase == ReadAloudPhase.Paused
            }
            FocusChange.Gained -> if (pausedForFocus) {
                pausedForFocus = false
                engine?.resume()
                mutableState.update { it.copy(phase = ReadAloudPhase.Speaking) }
            }
        }
    }
}
