package com.justspeaktoit.android.diagnostics

import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.dictation.ModeStatus
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.ui.MicPermission

/** Gathers Android's facts for [TroubleshootingRules]; the verdicts themselves are shared with iOS. */
object AndroidTroubleshooting {
    fun input(state: DictationUiState, mic: MicPermission, keyboardEnabled: Boolean): TroubleshootingInput {
        val cloud = state.activeMode == RecognitionMode.Cloud
        val transcription = state.sessionCloudModel.provider
        val cleanup = state.sessionCleanupModel.provider
        return TroubleshootingInput(
            microphone = when (mic) {
                MicPermission.Granted -> MicrophoneState.Granted
                // Android asks again until the user picks "Don't allow" twice.
                MicPermission.NotRequested, MicPermission.Denied -> MicrophoneState.NotDetermined
                MicPermission.DeniedPermanently -> MicrophoneState.Denied
            },
            recogniser = if (cloud) RecogniserState.NotRequired else recogniser(state),
            transcription = if (cloud) {
                TroubleshootingProvider(transcription.displayName, keyState(transcription, state))
            } else {
                TroubleshootingProvider.None
            },
            postProcessingEnabled = state.sessionCleanupEnabled,
            postProcessing = TroubleshootingProvider(cleanup.displayName, keyState(cleanup, state)),
            keyboard = if (keyboardEnabled) KeyboardState.Ready else KeyboardState.NotAdded,
        )
    }

    /**
     * The fixes this screen can carry out. Android cannot check a key with its provider, and turning cleanup
     * off in Settings does nothing while the active profile decides it.
     */
    fun fixes(finding: TroubleshootingFinding, state: DictationUiState): List<TroubleshootingFix> =
        finding.fixes.filter { fix ->
            when (fix) {
                TroubleshootingFix.VerifyKey, TroubleshootingFix.RequestSpeechRecognition -> false
                TroubleshootingFix.DisablePostProcessing -> state.profile?.cleanupEnabled == null
                else -> true
            }
        }

    /**
     * The recogniser the chosen mode uses. With nothing usable and nothing chosen, the on-device model's
     * state explains why, for example a model still to download.
     */
    private fun recogniser(state: DictationUiState): RecogniserState {
        val mode = state.activeMode ?: RecognitionMode.OnDevice
        val status = state.options.firstOrNull { it.mode == mode }?.status ?: return RecogniserState.Unknown
        return when (status) {
            ModeStatus.Ready -> RecogniserState.Ready
            ModeStatus.NeedsDownload, ModeStatus.Downloading -> RecogniserState.NeedsDownload
            ModeStatus.LanguageUnsupported -> RecogniserState.UnsupportedLanguage
            ModeStatus.RequiresNewerAndroid, ModeStatus.NotProvided -> RecogniserState.Unavailable
            ModeStatus.Unverified -> RecogniserState.Unknown
            ModeStatus.NeedsKey -> RecogniserState.NotRequired
        }
    }

    private fun keyState(provider: CloudProvider, state: DictationUiState): KeyState = when {
        provider in state.rejectedKeys -> KeyState.Rejected
        provider !in state.savedKeys -> KeyState.Missing
        provider in state.keyErrors -> KeyState.Unreadable
        else -> KeyState.Present
    }
}
