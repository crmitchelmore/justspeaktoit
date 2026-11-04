package com.justspeaktoit.android.dictation

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.Locale

data class DictationUiState(
    val dictation: DictationState = DictationState.Idle,
    val options: List<ModeAvailability> = emptyList(),
    /** The user's explicit choice; null means "use the best available mode". */
    val chosenMode: RecognitionMode? = null,
    val languageTag: String = Locale.getDefault().toLanguageTag(),
    val onDeviceLanguageTag: String = languageTag,
    val checkingAvailability: Boolean = true,
) {
    /** The mode a new session would use. */
    val activeMode: RecognitionMode?
        get() = chosenMode ?: RecognizerAvailability.defaultMode(options)

    /** While a session runs, its own mode, so a refresh can never relabel its privacy. */
    val displayedMode: RecognitionMode?
        get() = when (dictation) {
            is DictationState.Starting -> dictation.mode
            is DictationState.Listening -> dictation.mode
            is DictationState.Finishing -> dictation.mode
            else -> activeMode
        }

    val activeAvailability: ModeAvailability?
        get() = options.firstOrNull { it.mode == displayedMode }

    /** Starting waits for a coherent availability result for the current language. */
    val canStart: Boolean
        get() = !dictation.isActive && !checkingAvailability &&
            options.firstOrNull { it.mode == activeMode }?.usable == true
}

class DictationViewModel(application: Application) : AndroidViewModel(application) {
    private val engine = AndroidSpeechEngine(application)
    private val _state = MutableStateFlow(DictationUiState())
    val state: StateFlow<DictationUiState> = _state.asStateFlow()

    // Kept separate so microphone level updates only recompose the level indicator.
    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level.asStateFlow()

    /** Called whenever the screen starts, so newly installed models or services are noticed. */
    fun refreshAvailability() {
        if (_state.value.dictation.isActive) return
        val caps = engine.capabilities()
        val tag = Locale.getDefault().toLanguageTag()
        _state.update { it.copy(languageTag = tag, checkingAvailability = true) }
        engine.checkOnDeviceLanguage(tag) { resolution ->
            _state.update {
                it.copy(
                    options = RecognizerAvailability.evaluate(caps, resolution.support),
                    onDeviceLanguageTag = resolution.languageTag,
                    checkingAvailability = false,
                )
            }
        }
    }

    fun chooseMode(mode: RecognitionMode) {
        if (_state.value.dictation.isActive) return
        _state.update { it.copy(chosenMode = mode) }
    }

    private var downloadWatch: Job? = null

    /**
     * Requests the model, then rechecks support until it is installed or the wait ends, so Start
     * becomes available without leaving the app (the platform reports progress only via rechecks).
     */
    fun downloadOnDeviceModel() {
        engine.requestOnDeviceModel(_state.value.onDeviceLanguageTag)
        downloadWatch?.cancel()
        downloadWatch = viewModelScope.launch {
            repeat(DOWNLOAD_CHECKS) {
                delay(DOWNLOAD_CHECK_INTERVAL_MS)
                refreshAvailability()
                val status = _state.value.options.firstOrNull { it.mode == RecognitionMode.OnDevice }?.status
                if (status != ModeStatus.NeedsDownload && status != ModeStatus.Downloading) return@launch
            }
        }
    }

    fun start() {
        val current = _state.value
        val mode = current.activeMode ?: return
        if (!current.canStart) return
        dispatch(DictationEvent.Start(mode))
        val tag = if (mode == RecognitionMode.OnDevice) current.onDeviceLanguageTag else current.languageTag
        engine.start(mode, tag, onEvent = ::dispatch, onLevel = { _level.value = it })
    }

    fun stop() {
        if (!_state.value.dictation.isActive) return
        dispatch(DictationEvent.StopRequested)
        engine.stop()
    }

    fun cancel() {
        engine.cancel()
        dispatch(DictationEvent.Cancelled)
    }

    /** Android does not let a foreground-only app keep the microphone once it leaves the screen. */
    fun onLeftApp() {
        if (!_state.value.dictation.isActive) return
        engine.cancel()
        dispatch(DictationEvent.Error(DictationFailure.LeftApp))
    }

    fun clearResult() {
        if (_state.value.dictation.isActive) return
        _state.update { it.copy(dictation = DictationState.Idle) }
    }

    private fun dispatch(event: DictationEvent) {
        _state.update { it.copy(dictation = DictationReducer.reduce(it.dictation, event)) }
        if (!_state.value.dictation.isActive) _level.value = 0f
    }

    override fun onCleared() {
        engine.close()
    }

    private companion object {
        const val DOWNLOAD_CHECK_INTERVAL_MS = 5_000L
        const val DOWNLOAD_CHECKS = 60
    }
}
