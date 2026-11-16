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
     * The keyboard uses only the platform recognisers, so a saved Cloud or Downloaded choice is treated as
     * no choice. It never uses the app's Cloud (BYOK) providers until their privacy UX is reviewed (see
     * Docs/android-input-surfaces.md). Downloaded Whisper models stay out of the keyboard until their
     * load time, memory and transcription speed are measured on real phones (#1658,
     * Docs/android-on-device-models.md): the keyboard's process has a tighter memory budget than the app
     * and the user is waiting in another app's text field. An explicit on-device or speech-service choice
     * is honoured and never silently replaced if unusable.
     */
    fun mode(chosen: RecognitionMode?, options: List<ModeAvailability>): RecognitionMode? {
        val platform = options.filter { it.mode !in APP_ONLY_MODES }
        return if (chosen != null && chosen !in APP_ONLY_MODES) {
            chosen.takeIf { mode -> platform.any { it.mode == mode && it.usable } }
        } else {
            RecognizerAvailability.defaultMode(platform)
        }
    }

    /** Modes the app offers but the keyboard does not. */
    private val APP_ONLY_MODES = setOf(RecognitionMode.Cloud, RecognitionMode.Downloaded)

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
