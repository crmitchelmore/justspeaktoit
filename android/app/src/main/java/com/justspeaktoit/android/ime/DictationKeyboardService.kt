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
import androidx.annotation.StringRes
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.justspeaktoit.android.MainActivity
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.AndroidAudioInputs
import com.justspeaktoit.android.cloud.AzureSpeechCredential
import com.justspeaktoit.android.cloud.CallHandle
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudClient
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.WavRecorder
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.dictation.AndroidAudioInterruptions
import com.justspeaktoit.android.dictation.AndroidSpeechEngine
import com.justspeaktoit.android.dictation.CloudCapture
import com.justspeaktoit.android.dictation.DictationEvent
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.DictationLanguages
import com.justspeaktoit.android.dictation.DictationReducer
import com.justspeaktoit.android.dictation.DictationState
import com.justspeaktoit.android.dictation.DictationTimings
import com.justspeaktoit.android.dictation.DownloadedCleanup
import com.justspeaktoit.android.dictation.DownloadedTranscription
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.dictation.RecognizerAvailability
import com.justspeaktoit.android.dictation.SessionRequests
import com.justspeaktoit.android.local.AndroidLocalModels
import com.justspeaktoit.android.local.LocalCleanupPrompt
import com.justspeaktoit.android.local.PinnedModel
import com.justspeaktoit.android.local.PinnedModels
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.resources.SystemResourceToken
import com.justspeaktoit.android.security.KeystoreSecretStore
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.settings.DictationProfile
import com.justspeaktoit.android.settings.DictationProfiles
import com.justspeaktoit.android.ui.label
import com.justspeaktoit.android.ui.message
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * A minimal dictation keyboard: the Android equivalent of the Mac's insert-at-cursor. Live partial
 * text is shown as composing text; only a final transcript is committed. A failed or cancelled
 * session removes only its own composing text. Dictation inserts after a selection rather than
 * replacing it, so a failure can never lose the user's existing text. The phone's speech service, which
 * may send audio to its provider, is used only after the user has been told so. The profile key switches
 * the shared active profile; for dictation its language and Cloud model apply.
 *
 * Live Cloud dictation (#1668) is an explicit opt-in in Settings: with it on and Cloud chosen in the app,
 * the keyboard streams to the session's live Cloud model through the app's own session controller
 * ([KeyboardLiveDictation]), reading the key in process. Partials are composing text and the final text is
 * committed. A batch Cloud model, a missing key or a stream that has not settled within
 * [KeyboardPolicy.FINISH_TIMEOUT_MS] fails visibly; no other recogniser is tried instead.
 *
 * Edit rewrites the selection by voice (feature F22): the spoken instruction is recognised like
 * dictation, then the selected text and the instruction (never audio) go to the user's cleanup model,
 * after the keyboard has named that provider once. The rewrite replaces the selection only if the same
 * field still holds the same selection; otherwise, and on any failure, the text is left as it was.
 *
 * Downloaded models (#1650, #1660) run here only when [KeyboardLocalModels] estimates they finish within
 * [KeyboardPolicy.FINISH_TIMEOUT_MS]. A chosen downloaded Whisper model records for at most its estimated
 * limit and transcribes on the phone; a slower or missing one leaves the platform recogniser in use, and the
 * status line says why. A downloaded cleanup model (the profile's, else the user's) cleans up the final
 * text while the words already show as composing text; a run that would not fit, runs past the bound or
 * fails types the words as said and says so. Cloud and Gemini Nano cleanup never run in the keyboard.
 */
class DictationKeyboardService : InputMethodService() {
    private lateinit var engine: AndroidSpeechEngine
    private var state: DictationState = DictationState.Idle
    private var editorAllowsDictation = true
    private var checking = false
    private var inputVisible = false

    /** No on-device or speech-service recognition is usable; the keyboard never falls back to the cloud. */
    private var unavailable = false

    /** Cloud is chosen and opted in, but the session's model is batch only; named in the status line. */
    private var batchCloudModel: CloudModel? = null

    /** The provider the running live Cloud session streams to, named while listening. */
    private var cloudProvider: String? = null

    /** Main-thread scope for the live Cloud session; cancelled with the keyboard. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var liveDictation: KeyboardLiveDictation? = null

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

    /** The voice edit from its first tap until it is applied or abandoned; null when none runs. */
    private var voiceEdit: VoiceEditRun? = null

    /** The last voice edit's or keyboard cleanup's result or disclosure, shown until the next tap or field. */
    private var voiceEditNotice: String? = null

    /** Set after the cleanup provider has been named; the next Edit tap sends. */
    private var cloudEditDisclosed = false

    /** The speech-service disclosure was shown for Edit, so it asks for Edit to be tapped again. */
    private var disclosingForEdit = false

    private val voiceEditWork: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "jsti-voice-edit").apply { isDaemon = true }
    }
    private val rewriter by lazy { VoiceEditRewriter(CloudClient(), KeystoreSecretStore.create(this)) }

    private var status: TextView? = null
    private var microphoneHold: SystemResourceToken? = null
    private var mic: ImageButton? = null
    private var profileKey: Button? = null
    private var editingKeys: List<Button> = emptyList()
    private var voiceEditKey: Button? = null

    /** The downloaded model cleaning up the last transcript, shown as composing text meanwhile. */
    private var cleanupRun: CleanupRun? = null

    /** The downloaded Whisper model the running session uses, named in its status. */
    private var downloadedRun: WhisperChoice? = null

    /** A chosen downloaded Whisper model the keyboard could not use for this session, and why. */
    private var downloadedSkipped: WhisperChoice? = null

    /** The longest recording the next live or downloaded session may make, read by its recorder. */
    private var recordingLimitSeconds = DEFAULT_RECORDING_SECONDS

    /** Hashes the chosen cleanup model's weights ahead of the first dictation, so cleanup can start sooner. */
    private var prewarm: Job? = null

    /** The app's downloaded-model catalogues and stores; built on first use. */
    private val localSetup by lazy {
        AndroidLocalModels.setup(this, Dispatchers.IO, KeyboardPolicy.FINISH_TIMEOUT_MS + NATIVE_GRACE_MS)
    }

    private val keyboardCleanup by lazy {
        localSetup.cleanup?.let { setup ->
            KeyboardCleanup(
                cleanup = DownloadedCleanup(
                    installed = ::installedCleanupModel,
                    verify = setup.verifier::verify,
                    cleaner = setup.cleaner,
                    io = Dispatchers.IO,
                    timeoutMs = KeyboardPolicy.FINISH_TIMEOUT_MS + NATIVE_GRACE_MS,
                ),
                installed = ::installedCleanupModel,
                verified = setup.verifier::isVerified,
            )
        }
    }

    /** Read when the keyboard is shown or the profile changes, not on every partial result. */
    private var profiles: List<DictationProfile> = emptyList()
    private var activeProfile: DictationProfile? = null

    /** Learns corrections from the user's edits to text the keyboard inserted. */
    private val corrections = KeyboardCorrectionObserver(
        prefs = { AppPreferences(this) },
        connection = { currentInputConnection },
        editor = { currentInputEditorInfo },
        busy = { state.isActive || ownsComposing || voiceEdit != null || cleanupRun != null },
        hasSelection = { selectionStart != selectionEnd },
    )

    override fun onCreate() {
        super.onCreate()
        engine = AndroidSpeechEngine(this)
        // A keyboard killed mid-stream leaves its local copy of the audio behind; nothing ever reads it.
        File(cacheDir, LIVE_DIR).listFiles()?.forEach(File::delete)
    }

    override fun onDestroy() {
        corrections.cancel()
        voiceEdit?.call?.cancel()
        voiceEdit = null
        voiceEditWork.shutdownNow()
        liveDictation?.close()
        liveDictation = null
        scope.cancel()
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
        val profileButton = key(R.id.keyboard_profile, R.string.profile_none) { cycleProfile() }.apply {
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        val editButton = key(R.id.keyboard_voice_edit, R.string.keyboard_voice_edit) { onVoiceEditTapped() }
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            addView(profileButton)
            addView(editButton)
        }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(4), dp(8), dp(12))
            addView(key(R.id.keyboard_switch, R.string.keyboard_switch) { switchKeyboard() })
            addView(micButton)
            // While cleanup holds the words as composing text, editing keys would change what it replaces.
            editingKeys = listOf(
                key(R.id.keyboard_delete, R.string.keyboard_delete) { sendKeyUnlessCleaning(KeyEvent.KEYCODE_DEL) },
                key(R.id.keyboard_enter, R.string.keyboard_enter) { sendKeyUnlessCleaning(KeyEvent.KEYCODE_ENTER) },
            )
            editingKeys.forEach { addView(it) }
        }
        status = statusView
        mic = micButton
        profileKey = profileButton
        voiceEditKey = editButton
        loadProfiles()
        render()
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // The IME window is transparent, so without this the app behind shows through the keys.
            setBackgroundColor(themeColor(android.R.attr.colorBackground, Color.BLACK))
            addView(statusView)
            addView(actions)
            addView(row)
            // Android 15 draws the keyboard edge to edge: keep the keys clear of the navigation bar.
            ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                val bottom = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
                view.setPadding(0, 0, 0, bottom)
                insets
            }
        }
    }

    private fun themeColor(attr: Int, fallback: Int): Int {
        val value = TypedValue()
        val isColor = theme.resolveAttribute(attr, value, true) &&
            value.type in TypedValue.TYPE_FIRST_COLOR_INT..TypedValue.TYPE_LAST_COLOR_INT
        return if (isColor) value.data else fallback
    }

    override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        corrections.inputStarted(attribute)
    }

    override fun onFinishInput() {
        // Edits are read only from the field the text went into, while this keyboard is still in it.
        corrections.cancel()
        super.onFinishInput()
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        // A new or restarted editor (for example one that became a password field) ends any session.
        abandonForNewInput()
        selectionStart = info.initialSelStart
        selectionEnd = info.initialSelEnd
        editorAllowsDictation = KeyboardPolicy.allowsDictation(info.inputType)
        inputVisible = true
        // The profile may have changed in the app since the keyboard was last shown.
        loadProfiles()
        prewarmCleanup()
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
        disclosingForEdit = false
        voiceEditNotice = null
        // Cleared before the session is cancelled, so its Cancelled event is not reported as the user's.
        voiceEdit?.call?.cancel()
        voiceEdit = null
        abandonCleanup()
        if (state.isActive) cancelSession()
    }

    private fun sendKeyUnlessCleaning(keyCode: Int) {
        if (cleanupRun == null) sendDownUpKeyEvents(keyCode)
    }

    /** Stops a cleanup still running; the words it was given stay in the field as typed text. */
    private fun abandonCleanup() {
        val run = cleanupRun ?: return
        cleanupRun = null
        run.job?.cancel()
        if (ownsComposing) currentInputConnection?.finishComposingText()
        ownsComposing = false
        editorShowedComposing = false
    }

    private fun onMicTapped() {
        when {
            // Finishing is bounded by the engine's deadline; further taps must not extend it.
            state is DictationState.Finishing || cleanupRun != null -> Unit
            state.isActive -> stopSession()
            voiceEdit != null || !editorAllowsDictation -> Unit
            !hasMicPermission() -> openApp()
            else -> {
                voiceEditNotice = null
                startSession()
            }
        }
    }

    private fun onVoiceEditTapped() {
        val running = voiceEdit
        when {
            running != null -> when {
                checking || state is DictationState.Finishing -> Unit
                // Stops listening; the instruction heard so far is the edit.
                state.isActive -> stopSession()
                else -> cancelVoiceEdit(running)
            }
            state.isActive || checking || !editorAllowsDictation || cleanupRun != null -> Unit
            !hasMicPermission() -> openApp()
            else -> beginVoiceEdit()
        }
    }

    /** Captures the selection and its field, then reads the provider key before the microphone opens. */
    private fun beginVoiceEdit() {
        voiceEditNotice = null
        val info = currentInputEditorInfo
        val target = VoiceEditRules.capture(
            packageName = info?.packageName,
            fieldId = info?.fieldId ?: 0,
            selectionStart = selectionStart,
            selectionEnd = selectionEnd,
            selectedText = currentInputConnection?.getSelectedText(0),
        )
        if (target == null) {
            showVoiceEditNotice(voiceEditFailureNotice(VoiceEditFailure.NoSelection))
            return
        }
        val prefs = AppPreferences(this)
        val model = VoiceEditRules.model(DictationProfiles.active(prefs)?.cleanupModel, prefs.cleanupModelId)
        if (!cloudEditDisclosed) {
            // Say where the selected text goes before sending anything; the next tap confirms.
            cloudEditDisclosed = true
            showVoiceEditNotice(getString(R.string.keyboard_voice_edit_cloud_disclosure, model.cloudProvider.displayName))
            return
        }
        val run = VoiceEditRun(target, inputGeneration, model)
        voiceEdit = run
        render()
        voiceEditWork.execute {
            val key = rewriter.readKey(model)
            mainExecutor.execute { onVoiceEditKey(run, key) }
        }
    }

    private fun onVoiceEditKey(run: VoiceEditRun, key: VoiceEditKey) {
        if (voiceEdit !== run) return
        when (key) {
            is VoiceEditKey.Missing -> endVoiceEdit(voiceEditFailureNotice(key.failure))
            is VoiceEditKey.Found -> {
                run.apiKey = key.value
                startSession()
            }
        }
    }

    /** Sends the recognised instruction; the rewrite comes back to [finishVoiceEdit] on the main thread. */
    private fun beginRewrite(run: VoiceEditRun, instruction: String) {
        val key = run.apiKey ?: return endVoiceEdit(voiceEditFailureNotice(VoiceEditFailure.KeyUnavailable))
        run.rewriting = true
        voiceEditWork.execute {
            val outcome = rewriter.rewrite(run.model, key, run.target.selectedText, instruction, run.call)
            mainExecutor.execute { finishVoiceEdit(run, outcome) }
        }
    }

    private fun finishVoiceEdit(run: VoiceEditRun, outcome: VoiceEditOutcome) {
        if (voiceEdit !== run) return
        endVoiceEdit(
            when (outcome) {
                is VoiceEditOutcome.Rewritten -> if (replaceSelection(run, outcome.text)) {
                    getString(R.string.keyboard_voice_edit_done)
                } else {
                    voiceEditFailureNotice(VoiceEditFailure.TargetChanged)
                }
                is VoiceEditOutcome.Failed -> voiceEditFailureNotice(outcome.failure)
                VoiceEditOutcome.Cancelled -> getString(R.string.keyboard_voice_edit_cancelled)
            },
        )
    }

    /**
     * Replaces the selection with [text] only when the field, range and selected text are still the
     * ones the edit started on, so a rewrite can never land on text the user did not select.
     */
    private fun replaceSelection(run: VoiceEditRun, text: String): Boolean {
        val ic = currentInputConnection ?: return false
        val info = currentInputEditorInfo
        val current = VoiceEditRules.capture(
            packageName = info?.packageName,
            fieldId = info?.fieldId ?: 0,
            selectionStart = selectionStart,
            selectionEnd = selectionEnd,
            selectedText = ic.getSelectedText(0),
        )
        val sameInput = run.generation == inputGeneration && inputVisible
        if (!VoiceEditRules.stillTargets(run.target, current, sameInput)) return false
        // A model rewrite is not the user's correction of dictated text, so nothing may be learned from it.
        corrections.cancel()
        ic.beginBatchEdit()
        ic.finishComposingText()
        ic.commitText(text, 1)
        ic.endBatchEdit()
        return true
    }

    private fun cancelVoiceEdit(run: VoiceEditRun) {
        run.call.cancel()
        endVoiceEdit(getString(R.string.keyboard_voice_edit_cancelled))
    }

    private fun endVoiceEdit(notice: String) {
        voiceEdit = null
        showVoiceEditNotice(notice)
    }

    private fun showVoiceEditNotice(notice: String) {
        voiceEditNotice = notice
        render()
    }

    private fun voiceEditFailureNotice(failure: VoiceEditFailure): String = when (failure) {
        VoiceEditFailure.NoSelection -> getString(R.string.keyboard_voice_edit_no_selection)
        is VoiceEditFailure.MissingKey ->
            getString(R.string.keyboard_voice_edit_missing_key, failure.provider.displayName)
        VoiceEditFailure.KeyUnavailable -> unchanged(R.string.failure_key_unavailable)
        VoiceEditFailure.EmptyInstruction -> getString(R.string.keyboard_voice_edit_empty_instruction)
        VoiceEditFailure.EmptyRewrite -> getString(R.string.keyboard_voice_edit_empty_rewrite)
        VoiceEditFailure.TargetChanged -> getString(R.string.keyboard_voice_edit_target_changed)
        is VoiceEditFailure.Recognition -> unchanged(failure.failure.message())
        is VoiceEditFailure.Request -> unchanged(
            when (failure.failure) {
                DictationFailure.Network, DictationFailure.NetworkTimeout -> R.string.keyboard_voice_edit_network
                DictationFailure.InvalidKey -> R.string.failure_invalid_key
                else -> R.string.keyboard_voice_edit_failed
            },
        )
    }

    private fun unchanged(@StringRes message: Int): String =
        getString(R.string.keyboard_voice_edit_unchanged, getString(message))

    private fun startSession() {
        if (checking) return
        checking = true
        render()
        val caps = engine.capabilities()
        val prefs = AppPreferences(this)
        val tag = DictationLanguages.languageTag(DictationProfiles.active(prefs)?.language ?: prefs.languageId)
        val generation = inputGeneration
        // A voice edit records its instruction here; the selection must then stay as it is.
        val edit = voiceEdit
        engine.checkOnDeviceLanguage(tag) { resolution ->
            // Only the editor that was tapped, if still eligible, may start capture.
            if (generation != inputGeneration || !inputVisible || !editorAllowsDictation) return@checkOnDeviceLanguage
            checking = false
            if (edit !== voiceEdit) {
                // The edit was cancelled meanwhile, so nothing may be recorded for it.
                render()
                return@checkOnDeviceLanguage
            }
            val options = RecognizerAvailability.evaluate(caps, resolution.support)
            val current = AppPreferences(this)
            val chosen = current.chosenMode
            val cloudModel = DictationProfiles.active(current)?.cloudModel
                ?: CloudCatalog.transcriptionModel(current.cloudModelId)
            // A voice edit's instruction is always heard on the phone.
            val cloud = if (edit != null) {
                KeyboardCloud.Off
            } else {
                KeyboardPolicy.cloud(current.keyboardLiveCloudEnabled, cloudModel.live != null)
            }
            // A voice edit's instruction is never given to a downloaded model.
            val whisper = if (edit == null && chosen == RecognitionMode.Downloaded) whisperChoice(current) else null
            val mode = KeyboardPolicy.mode(chosen, options, cloud, downloaded = whisper?.usable == true)
            downloadedSkipped = whisper?.takeIf { mode != RecognitionMode.Downloaded }
            if (mode == null) {
                unavailable = true
                batchCloudModel = cloudModel.takeIf { KeyboardPolicy.blamesBatchCloud(chosen, cloud) }
                voiceEdit = null
                render()
                return@checkOnDeviceLanguage
            }
            unavailable = false
            batchCloudModel = null
            if (KeyboardPolicy.needsDisclosure(mode, chosen) && !speechServiceDisclosed) {
                // Say where audio goes before any capture; the next tap confirms.
                speechServiceDisclosed = true
                disclosing = true
                disclosingForEdit = edit != null
                voiceEdit = null
                render()
                return@checkOnDeviceLanguage
            }
            disclosing = false
            disclosingForEdit = false
            ownsComposing = false
            // Insert after any selection instead of replacing it.
            if (edit == null && selectionStart != selectionEnd && selectionEnd >= 0) {
                currentInputConnection?.setSelection(selectionEnd, selectionEnd)
            }
            downloadedRun = null
            if (mode == RecognitionMode.Cloud) {
                cloudProvider = cloudModel.provider.displayName
                recordingLimitSeconds = DEFAULT_RECORDING_SECONDS
                live().start(cloudModel, tag)
                return@checkOnDeviceLanguage
            }
            cloudProvider = null
            if (mode == RecognitionMode.Downloaded && whisper != null) {
                downloadedRun = whisper
                recordingLimitSeconds = whisper.limitSeconds
                live().startLocal(whisper.id, tag)
                return@checkOnDeviceLanguage
            }
            dispatch(DictationEvent.Start(mode))
            val language = if (mode == RecognitionMode.OnDevice) resolution.languageTag else tag
            engine.start(mode, language, onEvent = ::dispatch, onLevel = {})
        }
    }

    private fun stopSession() {
        val live = liveDictation
        if (live != null && live.isRunning) {
            // The session's own Finishing state arrives through onLiveState.
            live.stop()
            return
        }
        dispatch(DictationEvent.StopRequested)
        engine.stop()
    }

    private fun cancelSession() {
        engine.cancel()
        liveDictation?.cancel()
        removeOwnComposingText()
        dispatch(DictationEvent.Cancelled)
    }

    /** The live Cloud session, built on first use so a keyboard that never streams opens nothing. */
    private fun live(): KeyboardLiveDictation = liveDictation ?: run {
        val secrets = KeystoreSecretStore.create(this)
        val inputs = AndroidAudioInputs(this)
        val dir = File(cacheDir, LIVE_DIR).apply { mkdirs() }
        val capture = CloudCapture(
            recorders = { file, onLevel, onLimitReached, onCaptureFailed ->
                // A saved microphone that is not connected records from the system default, as in the app.
                val input = AppPreferences(this).audioInputId?.let(inputs::route)
                WavRecorder(file, onLevel, onLimitReached, onCaptureFailed, recordingLimitSeconds, input)
            },
            cacheDir = dir,
            io = Dispatchers.IO,
            resources = SystemResourceRegistry.shared,
        )
        val cloud = CloudClient(azureEndpoint = { secrets.read(AzureSpeechCredential.ENDPOINT_SECRET).orEmpty() })
        KeyboardLiveDictation(
            engine = engine,
            capture = capture,
            requests = SessionRequests(cloud, secrets, capture, Dispatchers.IO, DictationTimings()) { _, _ -> },
            resources = SystemResourceRegistry.shared,
            scope = scope,
            cacheDir = dir,
            corrections = { AppPreferences(this).corrections },
            silence = { AppPreferences(this).silence },
            onState = ::onLiveState,
            interruptions = AndroidAudioInterruptions(this),
            downloaded = DownloadedTranscription({ id -> installedWhisperModel(id)?.second }, localSetup.transcriber),
        ).also { liveDictation = it }
    }

    /** The live Cloud session's state; personal corrections are already applied to its final text. */
    private fun onLiveState(next: DictationState) {
        state = next
        applyState(corrected = true)
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
        val hadSelection = selectionStart != selectionEnd
        selectionStart = newSelStart
        selectionEnd = newSelEnd
        // Edit is offered only while something is selected.
        if (hadSelection != (newSelStart != newSelEnd)) render()
        if (newSelStart == 0 && newSelEnd == 0) corrections.cursorAtStart()
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
        if (event == DictationEvent.EndOfSpeech) return
        state = DictationReducer.reduce(state, event)
        applyState(corrected = false)
    }

    /** Writes the session's [state] to the field: partials as composing text, then the final text. */
    private fun applyState(corrected: Boolean) {
        val edit = voiceEdit
        if (edit != null) {
            dispatchForEdit(edit)
            reconcileMicrophoneHold()
            render()
            return
        }
        val ic = currentInputConnection
        when (val s = state) {
            is DictationState.Listening -> showPartial(s.partial)
            is DictationState.Finishing -> showPartial(s.partial)
            is DictationState.Done -> {
                state = DictationState.Idle
                val transcript = if (corrected) {
                    s.transcript
                } else {
                    PersonalCorrections.apply(s.transcript, AppPreferences(this).corrections)
                }
                val cleanupModel = keyboardCleanupModel()
                when {
                    ic == null -> ownsComposing = false
                    cleanupModel != null && !LocalCleanupPrompt.isEmpty(transcript) ->
                        beginCleanup(ic, cleanupModel, transcript)
                    else -> commitTranscript(ic, transcript)
                }
            }
            // Idle also arrives when Settings > System resources stops a live Cloud session.
            is DictationState.Failed, DictationState.Idle -> removeOwnComposingText()
            else -> Unit
        }
        reconcileMicrophoneHold()
        render()
    }

    /** Commits [transcript] in place of the session's provisional text, and watches it for corrections. */
    private fun commitTranscript(ic: android.view.inputmethod.InputConnection, transcript: String) {
        // Remove the provisional text first, so the spacing check sees the real preceding character.
        if (ownsComposing) ic.setComposingText("", 1)
        editorShowedComposing = false
        ownsComposing = false
        val text = KeyboardPolicy.textToCommit(transcript, ic.getTextBeforeCursor(1, 0))
        ic.commitText(text, 1)
        corrections.inserted(text, currentInputEditorInfo)
    }

    /** The downloaded cleanup model for keyboard dictation, by the app's rule; null runs no cleanup. */
    private fun keyboardCleanupModel(): String? {
        val setup = localSetup.cleanup ?: return null
        val prefs = AppPreferences(this)
        return KeyboardLocalModels.cleanupModelId(
            profile = DictationProfiles.active(prefs),
            cleanupEnabled = prefs.cleanupEnabled,
            userModelId = prefs.localCleanupModelId,
            catalog = setup.names.keys,
            installed = { installedCleanupModel(it) != null },
        )
    }

    /**
     * Shows [transcript] as composing text while [modelId] cleans it up, then commits the result; anything
     * but a cleaned-up result commits the words as said, with a notice saying why.
     */
    private fun beginCleanup(ic: android.view.inputmethod.InputConnection, modelId: String, transcript: String) {
        val cleaner = keyboardCleanup ?: return commitTranscript(ic, transcript)
        val prefs = AppPreferences(this)
        val prompt = DictationProfiles.active(prefs)?.prompt ?: prefs.cleanupPrompt?.takeIf { it.isNotBlank() }
        val name = localSetup.cleanup?.names?.get(modelId) ?: modelId
        if (!cleaner.fits(modelId, transcript, prompt)) {
            commitTranscript(ic, transcript)
            voiceEditNotice = getString(R.string.keyboard_cleanup_too_long, name)
            return
        }
        // The words show at once and stay provisional until the cleaned-up text replaces them. The partial
        // goes first, so the spacing check sees the real preceding character.
        if (ownsComposing) ic.setComposingText("", 1)
        // The editor's report of that empty region must not count as the composing text being ended.
        editorShowedComposing = false
        val shown = KeyboardPolicy.textToCommit(transcript, ic.getTextBeforeCursor(1, 0))
        ic.setComposingText(shown, 1)
        ownsComposing = true
        val run = CleanupRun(inputGeneration, name, shown)
        cleanupRun = run
        run.job = scope.launch {
            val result = cleaner.clean(modelId, transcript, prompt)
            finishCleanup(run, transcript, result)
        }
    }

    private fun finishCleanup(run: CleanupRun, transcript: String, result: KeyboardCleanupResult) {
        if (cleanupRun !== run) return
        cleanupRun = null
        val ic = currentInputConnection
        if (ic == null || run.generation != inputGeneration || !inputVisible) {
            ownsComposing = false
            render()
            return
        }
        if (!ownsComposing || ic.getTextBeforeCursor(run.shown.length, 0)?.toString() != run.shown) {
            // The app or the user ended or edited the composing text, so those words are theirs now.
            if (ownsComposing) ic.finishComposingText()
            ownsComposing = false
            editorShowedComposing = false
            voiceEditNotice = getString(R.string.keyboard_cleanup_text_changed, run.modelName)
            render()
            return
        }
        when (result) {
            is KeyboardCleanupResult.Applied -> {
                // Cleanup can restore a misheard word, so corrections run again on its output.
                commitTranscript(ic, PersonalCorrections.apply(result.text, AppPreferences(this).corrections))
                voiceEditNotice = getString(R.string.keyboard_cleanup_done, run.modelName)
            }
            else -> {
                commitTranscript(ic, transcript)
                voiceEditNotice = when (result) {
                    KeyboardCleanupResult.Empty -> null
                    KeyboardCleanupResult.TooLong -> getString(R.string.keyboard_cleanup_too_long, run.modelName)
                    KeyboardCleanupResult.TimedOut -> getString(R.string.keyboard_cleanup_timed_out, run.modelName)
                    else -> getString(R.string.keyboard_cleanup_failed, run.modelName)
                }
            }
        }
        render()
    }

    /** Hashes the chosen cleanup model's weights in the background, once per file version and process. */
    private fun prewarmCleanup() {
        if (prewarm?.isActive == true) return
        val setup = localSetup.cleanup ?: return
        val (model, file) = keyboardCleanupModel()?.let(::installedCleanupModel) ?: return
        if (setup.verifier.isVerified(model, file)) return
        prewarm = scope.launch(Dispatchers.IO) { setup.verifier.verify(model, file) }
    }

    private fun installedCleanupModel(id: String): Pair<PinnedModel, File>? {
        val setup = localSetup.cleanup ?: return null
        return PinnedModels.find(setup.catalog, id)?.takeIf(setup.store::isInstalled)?.let { it to setup.store.file(it) }
    }

    private fun installedWhisperModel(id: String): Pair<PinnedModel, File>? =
        PinnedModels.find(localSetup.catalog, id)?.takeIf(localSetup.store::isInstalled)
            ?.let { it to localSetup.store.file(it) }

    /** The chosen downloaded Whisper model and whether, by its estimate, the keyboard can use it. */
    private fun whisperChoice(prefs: AppPreferences): WhisperChoice? {
        val id = prefs.downloadedTranscriptionModel ?: return null
        val name = localSetup.names[id] ?: id
        val installed = installedWhisperModel(id)
        val limit = installed?.first?.bytes?.let(KeyboardLocalModels::whisperLimitSeconds) ?: 0
        val ready = installed != null && localSetup.transcriber.available
        return WhisperChoice(id, name, limit, ready)
    }

    /**
     * The instruction for a voice edit is never written into the field: partials only show in the
     * status line, and the final transcript is sent for the rewrite instead of being committed.
     */
    private fun dispatchForEdit(run: VoiceEditRun) {
        if (run.rewriting) return
        when (val s = state) {
            is DictationState.Done -> {
                state = DictationState.Idle
                beginRewrite(run, s.transcript)
            }
            is DictationState.Failed -> endVoiceEdit(voiceEditFailureNotice(VoiceEditFailure.Recognition(s.failure)))
            // Cancelled while listening, for example from Settings > System resources in use.
            DictationState.Idle -> endVoiceEdit(getString(R.string.keyboard_voice_edit_cancelled))
            else -> Unit
        }
    }

    /** Lists the keyboard's capture in Settings > System resources in use, with a way to stop it. */
    private fun reconcileMicrophoneHold() {
        // A live Cloud session's controller lists its own hold, released with Settings > System resources.
        if (!state.holdsMicrophone || liveDictation?.isRunning == true) {
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
        val run = voiceEdit
        val notice = voiceEditNotice
        val cleaning = cleanupRun
        val text = when {
            !editorAllowsDictation -> getString(R.string.keyboard_password_field)
            !hasMicPermission() -> getString(R.string.keyboard_needs_permission)
            cleaning != null -> getString(R.string.keyboard_cleaning_up, cleaning.modelName)
            checking -> getString(R.string.state_starting)
            disclosing && disclosingForEdit -> getString(R.string.keyboard_voice_edit_speech_service_disclosure)
            disclosing -> getString(R.string.keyboard_speech_service_disclosure)
            run != null -> voiceEditStatus(run)
            notice != null -> notice
            unavailable && !state.isActive -> batchCloudModel?.let {
                getString(R.string.keyboard_cloud_not_live, it.displayName)
            } ?: getString(R.string.keyboard_unavailable)
            else -> when (val s = state) {
                DictationState.Idle, is DictationState.Done -> getString(R.string.keyboard_ready)
                is DictationState.Starting -> getString(R.string.state_starting)
                is DictationState.Listening ->
                    if (liveDictation?.isPaused == true) getString(R.string.state_paused) else listeningStatus(s.mode)
                is DictationState.Finishing -> getString(R.string.state_finishing)
                is DictationState.Failed -> failureStatus(s)
            }
        }
        statusView.text = text
        mic?.apply {
            // During a voice edit the microphone only stops the instruction.
            isEnabled = editorAllowsDictation && !checking && cleaning == null && (run == null || state.isActive)
            alpha = if (isEnabled) 1f else 0.4f
            setImageResource(if (state.isActive) R.drawable.ic_stop else R.drawable.ic_mic)
            contentDescription = getString(if (state.isActive) R.string.action_stop else R.string.action_start)
        }
        profileKey?.apply {
            val name = activeProfile?.name ?: getString(R.string.profile_none)
            visibility = if (profiles.isEmpty()) View.GONE else View.VISIBLE
            this.text = getString(R.string.keyboard_profile, name)
            contentDescription = getString(R.string.keyboard_profile_description, name)
            isEnabled = !state.isActive && !checking && run == null && cleaning == null
            alpha = if (isEnabled) 1f else 0.4f
        }
        editingKeys.forEach {
            it.isEnabled = cleaning == null
            it.alpha = if (it.isEnabled) 1f else 0.4f
        }
        // Read here: inside the button's apply, selectionStart would be the button's own TextView selection.
        val hasSelection = selectionStart != selectionEnd
        voiceEditKey?.apply {
            val listening = run != null && state.isActive
            isEnabled = if (run != null) {
                !checking && state !is DictationState.Finishing
            } else {
                editorAllowsDictation && !checking && !state.isActive && hasSelection && cleaning == null
            }
            alpha = if (isEnabled) 1f else 0.4f
            this.text = getString(
                when {
                    run == null -> R.string.keyboard_voice_edit
                    listening -> R.string.keyboard_voice_edit_stop
                    else -> R.string.keyboard_voice_edit_cancel
                },
            )
            contentDescription = getString(
                when {
                    run == null -> R.string.keyboard_voice_edit_description
                    listening -> R.string.keyboard_voice_edit_stop_description
                    else -> R.string.keyboard_voice_edit_cancel_description
                },
            )
        }
    }

    /** A live Cloud session names where the audio is going while it streams. */
    private fun listeningStatus(mode: RecognitionMode): String {
        val provider = cloudProvider
        val downloaded = downloadedRun
        val skipped = downloadedSkipped
        return when {
            mode == RecognitionMode.Cloud && provider != null -> getString(R.string.keyboard_listening_cloud, provider)
            mode == RecognitionMode.Downloaded && downloaded != null ->
                resources.getQuantityString(
                    R.plurals.keyboard_listening_downloaded,
                    downloaded.limitSeconds,
                    downloaded.name,
                    downloaded.limitSeconds,
                )
            skipped != null -> getString(
                if (skipped.ready) R.string.keyboard_downloaded_too_slow else R.string.keyboard_downloaded_not_ready,
                getString(mode.label()),
                skipped.name,
            )
            else -> getString(R.string.keyboard_listening, getString(mode.label()))
        }
    }

    private fun failureStatus(failed: DictationState.Failed): String {
        val downloaded = downloadedRun
        if (failed.mode == RecognitionMode.Downloaded && downloaded != null &&
            failed.failure == DictationFailure.NetworkTimeout
        ) {
            return getString(R.string.keyboard_downloaded_timeout, downloaded.name)
        }
        val provider = cloudProvider
        if (failed.mode != RecognitionMode.Cloud || provider == null) return getString(failed.failure.message())
        return when (failed.failure) {
            DictationFailure.MissingKey -> getString(R.string.keyboard_cloud_missing_key, provider)
            DictationFailure.NetworkTimeout -> getString(R.string.keyboard_cloud_timeout, provider)
            else -> getString(R.string.keyboard_cloud_failed, getString(failed.failure.message()))
        }
    }

    private fun voiceEditStatus(run: VoiceEditRun): String {
        if (run.rewriting) return getString(R.string.keyboard_voice_edit_rewriting, run.model.displayName)
        return when (val s = state) {
            is DictationState.Listening -> if (s.partial.isBlank()) {
                getString(R.string.keyboard_voice_edit_listening)
            } else {
                getString(R.string.keyboard_voice_edit_heard, s.partial)
            }
            is DictationState.Starting -> getString(R.string.keyboard_voice_edit_listening)
            is DictationState.Finishing -> getString(R.string.state_finishing)
            // Reading the provider key before the microphone opens.
            else -> getString(R.string.state_starting)
        }
    }

    private fun loadProfiles() {
        val prefs = AppPreferences(this)
        profiles = prefs.profiles
        activeProfile = DictationProfiles.active(prefs)
    }

    /** Steps through no profile, then each profile in the user's order; a running session keeps its own. */
    private fun cycleProfile() {
        if (state.isActive || checking) return
        val ids = listOf<String?>(null) + profiles.map { it.id }
        val next = ids[(ids.indexOf(activeProfile?.id) + 1) % ids.size]
        AppPreferences(this).activeProfileId = next
        loadProfiles()
        render()
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

    private companion object {
        /** Where a live Cloud session keeps its local copy of the audio until the session ends. */
        const val LIVE_DIR = "keyboard-live"

        /** The app's own Cloud recording limit, which live Cloud sessions keep. */
        const val DEFAULT_RECORDING_SECONDS = 600

        /** The runtime's own deadline is later than the keyboard's, so the keyboard's bound ends a slow run. */
        const val NATIVE_GRACE_MS = 1_000L
    }

    /** One keyboard cleanup; [generation] is the field it started in and [shown] the composing text it set. */
    private class CleanupRun(val generation: Long, val modelName: String, val shown: String) {
        var job: Job? = null
    }

    /**
     * A chosen downloaded Whisper model: [limitSeconds] is the longest recording its estimate allows (0 when
     * too slow), and [ready] says whether it is on the phone with its runtime.
     */
    private class WhisperChoice(val id: String, val name: String, val limitSeconds: Int, val ready: Boolean) {
        val usable: Boolean get() = ready && limitSeconds > 0
    }

    /** One voice edit: what it may replace, where it started and the request that rewrites it. */
    private class VoiceEditRun(val target: VoiceEditTarget, val generation: Long, val model: CleanupModel) {
        var apiKey: String? = null
        var rewriting = false
        val call = CallHandle()
    }
}
