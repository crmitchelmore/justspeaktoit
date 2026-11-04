package com.justspeaktoit.android.ime

import android.text.InputType
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
     * The keyboard never uploads audio: Cloud is excluded until its privacy UX is reviewed (see
     * Docs/android-input-surfaces.md). An explicit on-device or speech-service choice from the app is
     * honoured, and is never silently replaced if unusable.
     */
    fun mode(chosen: RecognitionMode?, options: List<ModeAvailability>): RecognitionMode? {
        val local = options.filter { it.mode != RecognitionMode.Cloud }
        return if (chosen != null && chosen != RecognitionMode.Cloud) {
            chosen.takeIf { mode -> local.any { it.mode == mode && it.usable } }
        } else {
            RecognizerAvailability.defaultMode(local)
        }
    }

    /** Text to commit: a separating space is added when the cursor follows a word. */
    fun textToCommit(transcript: String, before: CharSequence?): String {
        val text = transcript.trim()
        if (text.isEmpty()) return ""
        val last = before?.lastOrNull() ?: return text
        return if (last.isWhitespace() || last in "([{\"'") text else " $text"
    }
}
