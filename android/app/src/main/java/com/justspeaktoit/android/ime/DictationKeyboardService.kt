package com.justspeaktoit.android.ime

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.os.Build
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
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.ui.label
import com.justspeaktoit.android.ui.message
import java.util.Locale

/**
 * A minimal dictation keyboard: the Android equivalent of the Mac's insert-at-cursor. Live partial
 * text is shown as composing text; only a final transcript is committed. A failed or cancelled
 * session removes its composing text, so it never looks like typed input. Audio never leaves the
 * device through the keyboard except via the phone's own speech service when that mode is used.
 */
class DictationKeyboardService : InputMethodService() {
    private lateinit var engine: AndroidSpeechEngine
    private var state: DictationState = DictationState.Idle
    private var editorAllowsDictation = true
    private var checking = false
    private var inputVisible = false

    /** No on-device or speech-service recognition is usable; the keyboard never falls back to the cloud. */
    private var unavailable = false

    private var status: TextView? = null
    private var mic: ImageButton? = null

    override fun onCreate() {
        super.onCreate()
        engine = AndroidSpeechEngine(this)
    }

    override fun onDestroy() {
        engine.close()
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val accent = ContextCompat.getColor(this, R.color.brand_accent_deep)

        val statusView = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            setPadding(dp(12), dp(8), dp(12), dp(4))
        }
        val micButton = ImageButton(this).apply {
            setImageResource(R.drawable.ic_mic)
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(accent)
            }
            layoutParams = LinearLayout.LayoutParams(dp(72), dp(72)).apply { setMargins(dp(16), 0, dp(16), 0) }
            setOnClickListener { onMicTapped() }
        }
        fun key(label: Int, onClick: () -> Unit) = Button(this).apply {
            text = getString(label)
            isAllCaps = false
            setOnClickListener { onClick() }
        }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(4), dp(8), dp(12))
            addView(key(R.string.keyboard_switch) { switchKeyboard() })
            addView(micButton)
            addView(key(R.string.keyboard_delete) { sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL) })
            addView(key(R.string.keyboard_enter) { sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER) })
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
        editorAllowsDictation = KeyboardPolicy.allowsDictation(info.inputType)
        inputVisible = true
        render()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        // The field or the keyboard went away: abandon the session rather than typing into the next field.
        inputVisible = false
        checking = false
        if (state.isActive) cancelSession()
        super.onFinishInputView(finishingInput)
    }

    private fun onMicTapped() {
        when {
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
        engine.checkOnDeviceLanguage(tag) { resolution ->
            checking = false
            val options = RecognizerAvailability.evaluate(caps, resolution.support)
            val mode = KeyboardPolicy.mode(AppPreferences(this).chosenMode, options)
            // The field may have closed while availability was being checked.
            if (!inputVisible) return@checkOnDeviceLanguage
            if (mode == null) {
                unavailable = true
                render()
                return@checkOnDeviceLanguage
            }
            unavailable = false
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
        currentInputConnection?.setComposingText("", 1)
        dispatch(DictationEvent.Cancelled)
    }

    private fun dispatch(event: DictationEvent) {
        state = DictationReducer.reduce(state, event)
        val ic = currentInputConnection
        when (val s = state) {
            is DictationState.Listening -> ic?.setComposingText(s.partial, 1)
            is DictationState.Finishing -> ic?.setComposingText(s.partial, 1)
            is DictationState.Done -> {
                // Remove the provisional text first, so the spacing check sees the real preceding character.
                ic?.setComposingText("", 1)
                ic?.commitText(KeyboardPolicy.textToCommit(s.transcript, ic.getTextBeforeCursor(1, 0)), 1)
                state = DictationState.Idle
            }
            is DictationState.Failed -> ic?.setComposingText("", 1)
            else -> Unit
        }
        render()
    }

    private fun render() {
        val statusView = status ?: return
        val text = when {
            !editorAllowsDictation -> getString(R.string.keyboard_password_field)
            !hasMicPermission() -> getString(R.string.keyboard_needs_permission)
            checking -> getString(R.string.state_starting)
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && switchToNextInputMethod(false)) return
        getSystemService(android.view.inputmethod.InputMethodManager::class.java)?.showInputMethodPicker()
    }

    private fun hasMicPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** A keyboard cannot ask for runtime permissions, so the app is opened to do it. */
    private fun openApp() {
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
