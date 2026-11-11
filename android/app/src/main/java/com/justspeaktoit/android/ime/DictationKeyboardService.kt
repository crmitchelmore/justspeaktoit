package com.justspeaktoit.android.ime

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.justspeaktoit.android.MainActivity
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.AndroidSpeechEngine
import com.justspeaktoit.android.dictation.DictationEvent
import com.justspeaktoit.android.dictation.DictationReducer
import com.justspeaktoit.android.dictation.DictationState
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.dictation.RecognizerAvailability
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.resources.SystemResourceToken
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.ui.label
import com.justspeaktoit.android.ui.message
import java.util.Locale

/**
 * A minimal dictation keyboard: the Android equivalent of the Mac's insert-at-cursor. Live partial
 * text is shown as composing text; only a final transcript is committed. A failed or cancelled
 * session removes only its own composing text. Dictation inserts after a selection rather than
 * replacing it, so a failure can never lose the user's existing text. The
 * keyboard never uses the app's Cloud (BYOK) providers; the phone's speech service, which may send
 * audio to its provider, is used only after the user has been told so.
 */
class DictationKeyboardService : InputMethodService() {
    private lateinit var engine: AndroidSpeechEngine
    private var state: DictationState = DictationState.Idle
    private var editorAllowsDictation = true
    private var checking = false
    private var inputVisible = false

    /** No on-device or speech-service recognition is usable; the keyboard never falls back to the cloud. */
    private var unavailable = false

    /** Bumped whenever the editor changes, so a pending start cannot reach a different field. */
    private var inputGeneration = 0L

    /** Whether the editor still holds composing text written by this session. */
    private var ownsComposing = false

    /** The editor has reported our composing region, so a later report without one means it was ended. */
    private var editorShowedComposing = false
    private var selectionStart = -1
    private var selectionEnd = -1

    /** Set after the speech-service disclosure has been shown; the next tap starts capture. */
    private var speechServiceDisclosed = false
    private var disclosing = false

    private var status: TextView? = null
    private var microphoneHold: SystemResourceToken? = null
    private var mic: ImageButton? = null

    override fun onCreate() {
        super.onCreate()
        engine = AndroidSpeechEngine(this)
    }

    override fun onDestroy() {
        engine.close()
        microphoneHold?.end()
        microphoneHold = null
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val accent = ContextCompat.getColor(this, R.color.brand_accent_deep)

        val statusView = TextView(this).apply {
            id = R.id.keyboard_status
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            setPadding(dp(12), dp(8), dp(12), dp(4))
        }
        val micButton = ImageButton(this).apply {
            id = R.id.keyboard_mic
            setImageResource(R.drawable.ic_mic)
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(accent)
            }
            layoutParams = LinearLayout.LayoutParams(dp(72), dp(72)).apply { setMargins(dp(16), 0, dp(16), 0) }
            setOnClickListener { onMicTapped() }
        }
        fun key(viewId: Int, label: Int, onClick: () -> Unit) = Button(this).apply {
            id = viewId
            text = getString(label)
            isAllCaps = false
            setOnClickListener { onClick() }
        }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(4), dp(8), dp(12))
            addView(key(R.id.keyboard_switch, R.string.keyboard_switch) { switchKeyboard() })
            addView(micButton)
            addView(key(R.id.keyboard_delete, R.string.keyboard_delete) { sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL) })
            addView(key(R.id.keyboard_enter, R.string.keyboard_enter) { sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER) })
        }
        status = statusView
        mic = micButton
        render()
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(statusView)
            addView(row)
        }
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        // A new or restarted editor (for example one that became a password field) ends any session.
        abandonForNewInput()
        editorAllowsDictation = KeyboardPolicy.allowsDictation(info.inputType)
        inputVisible = true
        render()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        // The field or the keyboard went away: abandon the session rather than typing into the next field.
        inputVisible = false
        abandonForNewInput()
        super.onFinishInputView(finishingInput)
    }

    private fun abandonForNewInput() {
        inputGeneration++
        checking = false
        disclosing = false
        if (state.isActive) cancelSession()
    }

    private fun onMicTapped() {
        when {
            // Finishing is bounded by the engine's deadline; further taps must not extend it.
            state is DictationState.Finishing -> Unit
            state.isActive -> stopSession()
            !editorAllowsDictation -> Unit
            !hasMicPermission() -> openApp()
            else -> startSession()
        }
    }

    private fun startSession() {
        if (checking) return
        checking = true
        render()
        val caps = engine.capabilities()
        val tag = Locale.getDefault().toLanguageTag()
        val generation = inputGeneration
        engine.checkOnDeviceLanguage(tag) { resolution ->
            // Only the editor that was tapped, if still eligible, may start capture.
            if (generation != inputGeneration || !inputVisible || !editorAllowsDictation) return@checkOnDeviceLanguage
            checking = false
            val options = RecognizerAvailability.evaluate(caps, resolution.support)
            val chosen = AppPreferences(this).chosenMode
            val mode = KeyboardPolicy.mode(chosen, options)
            if (mode == null) {
                unavailable = true
                render()
                return@checkOnDeviceLanguage
            }
            unavailable = false
            if (KeyboardPolicy.needsDisclosure(mode, chosen) && !speechServiceDisclosed) {
                // Say where audio goes before any capture; the next tap confirms.
                speechServiceDisclosed = true
                disclosing = true
                render()
                return@checkOnDeviceLanguage
            }
            disclosing = false
            ownsComposing = false
            // Insert after any selection instead of replacing it.
            if (selectionStart != selectionEnd && selectionEnd >= 0) {
                currentInputConnection?.setSelection(selectionEnd, selectionEnd)
            }
            dispatch(DictationEvent.Start(mode))
            val language = if (mode == RecognitionMode.OnDevice) resolution.languageTag else tag
            engine.start(mode, language, onEvent = ::dispatch, onLevel = {})
        }
    }

    private fun stopSession() {
        dispatch(DictationEvent.StopRequested)
        engine.stop()
    }

    private fun cancelSession() {
        engine.cancel()
        removeOwnComposingText()
        dispatch(DictationEvent.Cancelled)
    }

    /** Removes provisional text the session wrote; text it does not own is never touched. */
    private fun removeOwnComposingText() {
        if (ownsComposing) currentInputConnection?.setComposingText("", 1)
        ownsComposing = false
        editorShowedComposing = false
    }

    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        candidatesStart: Int,
        candidatesEnd: Int,
    ) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        selectionStart = newSelStart
        selectionEnd = newSelEnd
        // Updates can lag behind our writes, so only an end after the editor showed our region counts:
        // the app or user ended composing, and that text is now theirs rather than provisional.
        if (!ownsComposing) return
        if (candidatesStart >= 0) {
            editorShowedComposing = true
        } else if (editorShowedComposing) {
            ownsComposing = false
            editorShowedComposing = false
        }
    }

    private fun showPartial(partial: String) {
        // Nothing is written until there are words, so an empty start cannot erase a selection.
        if (partial.isEmpty() && !ownsComposing) return
        currentInputConnection?.setComposingText(partial, 1)
        ownsComposing = true
    }

    private fun dispatch(event: DictationEvent) {
        state = DictationReducer.reduce(state, event)
        val ic = currentInputConnection
        when (val s = state) {
            is DictationState.Listening -> showPartial(s.partial)
            is DictationState.Finishing -> showPartial(s.partial)
            is DictationState.Done -> {
                if (ic != null) {
                    // Remove the provisional text first, so the spacing check sees the real preceding character.
                    if (ownsComposing) ic.setComposingText("", 1)
                    editorShowedComposing = false
                    ic.commitText(KeyboardPolicy.textToCommit(s.transcript, ic.getTextBeforeCursor(1, 0)), 1)
                }
                ownsComposing = false
                state = DictationState.Idle
            }
            is DictationState.Failed -> removeOwnComposingText()
            else -> Unit
        }
        reconcileMicrophoneHold()
        render()
    }

    /** Lists the keyboard's capture in Settings > System resources in use, with a way to stop it. */
    private fun reconcileMicrophoneHold() {
        val capturing = state is DictationState.Starting || state is DictationState.Listening
        if (!capturing) {
            microphoneHold?.end()
            microphoneHold = null
            return
        }
        if (microphoneHold != null) return
        microphoneHold = SystemResourceRegistry.shared.acquire(
            kind = SystemResourceKind.Microphone,
            title = "Keyboard dictation",
            reason = "Listening for text to type into the current field",
            owner = "DictationKeyboardService",
            releaseTitle = "Stop listening",
            release = { cancelSession() },
        )
    }

    private fun render() {
        val statusView = status ?: return
        val text = when {
            !editorAllowsDictation -> getString(R.string.keyboard_password_field)
            !hasMicPermission() -> getString(R.string.keyboard_needs_permission)
            checking -> getString(R.string.state_starting)
            disclosing -> getString(R.string.keyboard_speech_service_disclosure)
            unavailable && !state.isActive -> getString(R.string.keyboard_unavailable)
            else -> when (val s = state) {
                DictationState.Idle, is DictationState.Done -> getString(R.string.keyboard_ready)
                is DictationState.Starting -> getString(R.string.state_starting)
                is DictationState.Listening -> getString(R.string.keyboard_listening, getString(s.mode.label()))
                is DictationState.Finishing -> getString(R.string.state_finishing)
                is DictationState.Failed -> getString(s.failure.message())
            }
        }
        statusView.text = text
        mic?.apply {
            isEnabled = editorAllowsDictation && !checking
            alpha = if (isEnabled) 1f else 0.4f
            setImageResource(if (state.isActive) R.drawable.ic_stop else R.drawable.ic_mic)
            contentDescription = getString(if (state.isActive) R.string.action_stop else R.string.action_start)
        }
    }

    private fun switchKeyboard() {
        if (state.isActive) cancelSession()
        if (switchToNextInputMethod(false)) return
        getSystemService(android.view.inputmethod.InputMethodManager::class.java)?.showInputMethodPicker()
    }

    private fun hasMicPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** A keyboard cannot ask for runtime permissions, so the app is opened to do it. */
    private fun openApp() {
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
