package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.RecognitionMode

// User-facing names for dictation values, shared by the app screens and the keyboard.

@StringRes
internal fun RecognitionMode.label(): Int = when (this) {
    RecognitionMode.OnDevice -> R.string.mode_on_device
    RecognitionMode.SpeechService -> R.string.mode_speech_service
    RecognitionMode.Cloud -> R.string.mode_cloud
}

@StringRes
internal fun DictationFailure.message(): Int = when (this) {
    DictationFailure.NoSpeech -> R.string.failure_no_speech
    DictationFailure.NoMatch -> R.string.failure_no_match
    DictationFailure.Network -> R.string.failure_network
    DictationFailure.NetworkTimeout -> R.string.failure_network_timeout
    DictationFailure.Audio -> R.string.failure_audio
    DictationFailure.PermissionDenied -> R.string.failure_permission
    DictationFailure.RecognizerBusy -> R.string.failure_busy
    DictationFailure.Server -> R.string.failure_server
    DictationFailure.Client -> R.string.failure_client
    DictationFailure.TooManyRequests -> R.string.failure_too_many_requests
    DictationFailure.LanguageNotSupported -> R.string.failure_language_not_supported
    DictationFailure.LanguageUnavailable -> R.string.failure_language_unavailable
    DictationFailure.LeftApp -> R.string.failure_left_app
    DictationFailure.InterruptedByCall -> R.string.failure_interrupted_by_call
    DictationFailure.AudioFocusLost -> R.string.failure_audio_focus_lost
    DictationFailure.AudioDeviceChanged -> R.string.failure_audio_device_changed
    DictationFailure.RecordingRecovered -> R.string.failure_recording_recovered
    DictationFailure.Unavailable -> R.string.failure_unavailable
    DictationFailure.InvalidKey -> R.string.failure_invalid_key
    DictationFailure.KeyUnavailable -> R.string.failure_key_unavailable
    DictationFailure.MissingKey -> R.string.failure_missing_key
    DictationFailure.AudioTooLarge -> R.string.failure_audio_too_large
    DictationFailure.UnsupportedAudio -> R.string.failure_unsupported_audio
    DictationFailure.Unknown -> R.string.failure_unknown
}
