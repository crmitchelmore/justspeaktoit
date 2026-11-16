package com.justspeaktoit.android.ime

import android.text.InputType
import android.view.inputmethod.EditorInfo
import com.justspeaktoit.android.dictation.ModeAvailability
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.dictation.RecognizerAvailability

/** Pure rules for the dictation keyboard, kept separate so they are unit-tested. */
object KeyboardPolicy {
    /** Dictation is never offered in password fields, so spoken secrets are not sent to a recogniser. */
    fun allowsDictation(inputType: Int): Boolean {
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (inputType and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT -> variation != InputType.TYPE_TEXT_VARIATION_PASSWORD &&
                variation != InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD &&
                variation != InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> variation != InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> true
        }
    }

    /**
     * Edits are learned only in ordinary text fields: never in password fields, fields that ask for
     * no suggestions, or fields that ask keyboards not to learn from them (for example incognito tabs).
     */
    fun allowsLearning(inputType: Int, imeOptions: Int): Boolean =
        (inputType and InputType.TYPE_MASK_CLASS) == InputType.TYPE_CLASS_TEXT &&
            allowsDictation(inputType) &&
            (inputType and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS) == 0 &&
            (imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING) == 0

    /**
     * How long a stopped keyboard session may take to produce its final text, for every route. It
     * matches the speech recogniser's own finalise deadline; a live Cloud stream that has not settled
     * by then fails visibly.
     */
    const val FINISH_TIMEOUT_MS = 10_000L

    /**
     * Picks the keyboard's recogniser. A saved Cloud choice is used only after the user opted the
     * keyboard in to live Cloud models in Settings, and only when the session's Cloud model streams
     * live ([KeyboardCloud.Live]); a batch model is never uploaded instead and returns null, so the
     * keyboard says why rather than switching route. Without the opt-in a Cloud choice is treated as
     * no choice. Automatic never picks Cloud, and an explicit on-device or speech-service choice is
     * honoured and never silently replaced if unusable.
     */
    fun mode(
        chosen: RecognitionMode?,
        options: List<ModeAvailability>,
        cloud: KeyboardCloud = KeyboardCloud.Off,
    ): RecognitionMode? {
        if (chosen == RecognitionMode.Cloud && cloud != KeyboardCloud.Off) {
            return RecognitionMode.Cloud.takeIf { cloud == KeyboardCloud.Live }
        }
        val local = options.filter { it.mode != RecognitionMode.Cloud }
        return if (chosen != null && chosen != RecognitionMode.Cloud) {
            chosen.takeIf { mode -> local.any { it.mode == mode && it.usable } }
        } else {
            RecognizerAvailability.defaultMode(local)
        }
    }

    /** What the opt-in allows for a session, given whether the session's Cloud model streams live. */
    fun cloud(optedIn: Boolean, liveModel: Boolean): KeyboardCloud = when {
        !optedIn -> KeyboardCloud.Off
        liveModel -> KeyboardCloud.Live
        else -> KeyboardCloud.NotLive
    }

    /**
     * The speech service may send audio to its provider, so it is disclosed before capture unless
     * the user explicitly chose it in the app.
     */
    fun needsDisclosure(mode: RecognitionMode, chosen: RecognitionMode?): Boolean =
        mode == RecognitionMode.SpeechService && chosen != RecognitionMode.SpeechService

    /** Text to commit: a separating space is added when the cursor follows a word. */
    fun textToCommit(transcript: String, before: CharSequence?): String {
        val text = transcript.trim()
        if (text.isEmpty()) return ""
        val last = before?.lastOrNull() ?: return text
        return if (last.isWhitespace() || last in "([{\"'") text else " $text"
    }
}

/** Whether the keyboard may use the app's Cloud (BYOK) mode for a session. */
enum class KeyboardCloud {
    /** The user has not opted the keyboard in, so a Cloud choice is treated as no choice. */
    Off,

    /** Opted in, and the session's Cloud model streams live. */
    Live,

    /** Opted in, but the session's Cloud model is batch only, which the keyboard does not upload. */
    NotLive,
}
