package com.justspeaktoit.android.ime

import android.os.Handler
import android.os.Looper
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import com.justspeaktoit.android.corrections.AutoCorrectionLearner
import com.justspeaktoit.android.corrections.AutoCorrectionLearningPolicy
import com.justspeaktoit.android.corrections.CorrectionContext
import com.justspeaktoit.android.corrections.CorrectionSpan
import com.justspeaktoit.android.corrections.CorrectionWatch
import com.justspeaktoit.android.corrections.EditorKey
import com.justspeaktoit.android.corrections.TextWindow
import com.justspeaktoit.android.settings.DictationPreferences

/**
 * Watches text the keyboard inserted for the user's edits and passes them to [AutoCorrectionLearner],
 * like the Mac's `AutoCorrectionTracker`. After SpeakCore's observation time it reads the field again,
 * but only while this keyboard is still attached to the same field, and never a field that opts out of
 * learning. One insertion is watched at a time. Field text is never logged.
 */
internal class KeyboardCorrectionObserver(
    private val prefs: () -> DictationPreferences,
    private val connection: () -> InputConnection?,
    private val editor: () -> EditorInfo?,
    /** True while dictation is writing to the field, so a sample would read provisional text. */
    private val busy: () -> Boolean,
    private val hasSelection: () -> Boolean,
) {
    private val handler = Handler(Looper.getMainLooper())
    private var watch: CorrectionWatch? = null
    private val sample = Runnable { onTimer() }

    /** Call right after [committed] was committed at the cursor of the field described by [info]. */
    fun inserted(committed: String, info: EditorInfo?) {
        val ic = connection() ?: return
        val pending = watch
        if (pending != null && info != null && pending.editor == key(info) && locate(ic, pending) != null) {
            // The new text went into or beside the watched text, most likely re-dictating a word in it.
            return
        }
        cancel()
        if (info == null || committed.isEmpty() || !learnable(info) || !prefs().learnCorrections) return
        if (committed.length > AutoCorrectionLearningPolicy.MAXIMUM_UTF16_UNITS) return
        val before = ic.getTextBeforeCursor(committed.length + CorrectionSpan.CONTEXT_LENGTH, 0)?.toString() ?: return
        // An editor that reformatted the text as it went in has nothing the original can be compared with.
        if (!before.endsWith(committed)) return
        val after = ic.getTextAfterCursor(CorrectionSpan.CONTEXT_LENGTH, 0)?.toString() ?: return
        watch = CorrectionWatch(
            original = committed,
            context = CorrectionContext.of(before.dropLast(committed.length), after),
            editor = key(info),
            app = info.packageName,
        )
        handler.postDelayed(sample, AutoCorrectionLearningPolicy.observationSeconds(committed) * 1_000L)
    }

    /** A field started or restarted: a watch on any other field, or one that now opts out, ends. */
    fun inputStarted(info: EditorInfo) {
        val pending = watch ?: return
        if (pending.editor != key(info) || !learnable(info)) cancel()
    }

    /**
     * The cursor moved to the start of the field. An empty field means the text was sent or cleared,
     * so whatever is typed next is not an edit of it.
     */
    fun cursorAtStart() {
        if (watch == null) return
        val after = connection()?.getTextAfterCursor(1, 0)
        if (after != null && after.isEmpty()) cancel()
    }

    fun cancel() {
        watch = null
        handler.removeCallbacks(sample)
    }

    private fun onTimer() {
        if (watch == null) return
        if (busy()) {
            handler.postDelayed(sample, RETRY_MS)
            return
        }
        val pending = watch ?: return
        cancel()
        val info = editor() ?: return
        val preferences = prefs()
        if (!preferences.learnCorrections || key(info) != pending.editor || !learnable(info)) return
        val ic = connection() ?: return
        val edited = locate(ic, pending) ?: return
        AutoCorrectionLearner(preferences).recordEdit(pending.original, edited, pending.app)
    }

    private fun locate(ic: InputConnection, pending: CorrectionWatch): String? {
        val window = window(ic) ?: return null
        return CorrectionSpan.locate(window, pending.context)
    }

    /** The text either side of the cursor, selection included, up to [CorrectionSpan.WINDOW_LENGTH] each way. */
    private fun window(ic: InputConnection): TextWindow? {
        val limit = CorrectionSpan.WINDOW_LENGTH
        val before = ic.getTextBeforeCursor(limit, 0)?.toString() ?: return null
        val selected = ic.getSelectedText(0)?.toString()
        // Without the selected text the window would have a hole in it.
        if (selected == null && hasSelection()) return null
        val after = ic.getTextAfterCursor(limit, 0)?.toString() ?: return null
        return TextWindow(before + selected.orEmpty() + after, before.length < limit, after.length < limit)
    }

    private fun key(info: EditorInfo) = EditorKey(info.packageName, info.fieldId, info.inputType)

    private fun learnable(info: EditorInfo) = KeyboardPolicy.allowsLearning(info.inputType, info.imeOptions)

    private companion object {
        /** How soon to look again when dictation was writing to the field at the end of the watch. */
        const val RETRY_MS = 1_000L
    }
}
