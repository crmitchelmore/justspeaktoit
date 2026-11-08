package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.CleanupStatus
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.DictationState
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.dictation.ModeAvailability
import com.justspeaktoit.android.dictation.ModeStatus
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.output.TranscriptOutput
import com.justspeaktoit.android.ui.theme.BrandAccentDeep
import com.justspeaktoit.android.ui.theme.BrandAccentWarm
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.util.Locale

enum class MicPermission { Granted, NotRequested, Denied, DeniedPermanently }

data class DictationActions(
    val onRecordTapped: () -> Unit,
    val onStop: () -> Unit,
    val onCancel: () -> Unit,
    val onChooseMode: (RecognitionMode) -> Unit,
    val onDownloadModel: () -> Unit,
    val onClear: () -> Unit,
    val onOpenSettings: () -> Unit,
    val onShowSettings: () -> Unit,
    val onShowOriginal: () -> Unit,
    val onShowHistory: () -> Unit = {},
    val onConfirmSharedAudio: () -> Unit = {},
    val onDismissSharedAudio: () -> Unit = {},
)

@Composable
fun DictationScreen(
    state: DictationUiState,
    level: StateFlow<Float>,
    permission: MicPermission,
    actions: DictationActions,
) {
    val snackbar = remember { SnackbarHostState() }
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(R.string.app_name),
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = actions.onShowHistory, enabled = !state.dictation.isActive) {
                    Icon(
                        painter = painterResource(R.drawable.ic_history),
                        contentDescription = stringResource(R.string.history_title),
                    )
                }
                IconButton(onClick = actions.onShowSettings, enabled = !state.dictation.isActive) {
                    Icon(
                        painter = painterResource(R.drawable.ic_settings),
                        contentDescription = stringResource(R.string.settings_title),
                    )
                }
            }
            ModeSection(state, actions)
            TranscriptCard(state)
            PermissionNotice(permission, actions)
            RecordControls(state, level, actions)
            ResultActions(state, snackbar, actions)
        }
    }
    if (state.sharedAudio != null) {
        AlertDialog(
            onDismissRequest = actions.onDismissSharedAudio,
            title = { Text(stringResource(R.string.shared_audio_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.shared_audio_body,
                        state.cloudModel.provider.displayName,
                        state.cloudModel.displayName,
                    ),
                )
            },
            confirmButton = {
                TextButton(onClick = actions.onConfirmSharedAudio) {
                    Text(stringResource(R.string.action_transcribe))
                }
            },
            dismissButton = {
                TextButton(onClick = actions.onDismissSharedAudio) { Text(stringResource(R.string.action_cancel)) }
            },
        )
    }
}

@Composable
private fun ModeSection(state: DictationUiState, actions: DictationActions) {
    if (state.checkingAvailability && state.options.isEmpty()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            Text(stringResource(R.string.checking_availability), style = MaterialTheme.typography.bodyMedium)
        }
        return
    }
    val active = state.displayedMode
    Text(stringResource(R.string.mode_picker_label), style = MaterialTheme.typography.labelLarge)
    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
        state.options.forEachIndexed { index, option ->
            SegmentedButton(
                selected = option.mode == active,
                onClick = { actions.onChooseMode(option.mode) },
                enabled = !state.dictation.isActive,
                shape = SegmentedButtonDefaults.itemShape(index, state.options.size),
            ) {
                Text(stringResource(option.mode.label()))
            }
        }
    }
    val availability = state.activeAvailability ?: return
    val languageName = Locale.forLanguageTag(state.onDeviceLanguageTag).displayName
    Text(
        text = availability.explanation(languageName, state),
        style = MaterialTheme.typography.bodyMedium,
        color = if (availability.usable) {
            MaterialTheme.colorScheme.onSurfaceVariant
        } else {
            MaterialTheme.colorScheme.error
        },
    )
    if (availability.status == ModeStatus.NeedsDownload) {
        OutlinedButton(onClick = actions.onDownloadModel) {
            Text(stringResource(R.string.action_download_model))
        }
    }
}

@Composable
private fun TranscriptCard(state: DictationUiState) {
    val dictation = state.dictation
    val (text, secondary) = when (dictation) {
        is DictationState.Listening -> dictation.partial to true
        is DictationState.Finishing -> dictation.partial to true
        is DictationState.Done -> dictation.transcript to false
        is DictationState.Failed -> dictation.unfinishedText to true
        else -> "" to true
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = statusText(state),
                style = MaterialTheme.typography.labelLarge,
                color = if (dictation is DictationState.Failed) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.primary
                },
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
            if (dictation is DictationState.Failed && text.isNotEmpty()) {
                Text(stringResource(R.string.unfinished_label), style = MaterialTheme.typography.labelMedium)
            }
            CleanupNote(state.cleanup)
            Text(
                text = text.ifEmpty { stringResource(R.string.transcript_placeholder) },
                style = MaterialTheme.typography.bodyLarge,
                color = if (secondary || text.isEmpty()) {
                    MaterialTheme.colorScheme.onSurfaceVariant
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
            )
        }
    }
}

@Composable
private fun PermissionNotice(permission: MicPermission, actions: DictationActions) {
    when (permission) {
        MicPermission.Denied -> Text(
            stringResource(R.string.permission_rationale),
            style = MaterialTheme.typography.bodyMedium,
        )
        MicPermission.DeniedPermanently -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.permission_denied_settings), color = MaterialTheme.colorScheme.error)
            OutlinedButton(onClick = actions.onOpenSettings) { Text(stringResource(R.string.action_open_settings)) }
        }
        else -> Unit
    }
}

@Composable
private fun RecordControls(state: DictationUiState, level: StateFlow<Float>, actions: DictationActions) {
    val active = state.dictation.isActive
    val enabled = active || state.canStart
    val description = stringResource(if (active) R.string.action_stop else R.string.action_start)
    Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(132.dp)) {
            if (active) LevelHalo(level)
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(96.dp)
                    .clip(CircleShape)
                    .background(
                        if (enabled) {
                            Brush.linearGradient(listOf(BrandAccentDeep, BrandAccentWarm))
                        } else {
                            SolidColor(MaterialTheme.colorScheme.outline)
                        },
                    )
                    .clickable(enabled = enabled) { if (active) actions.onStop() else actions.onRecordTapped() }
                    .semantics {
                        role = Role.Button
                        contentDescription = description
                    },
            ) {
                Icon(
                    painter = painterResource(if (active) R.drawable.ic_stop else R.drawable.ic_mic),
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(40.dp),
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        if (active) {
            TextButton(onClick = actions.onCancel) { Text(stringResource(R.string.action_cancel)) }
        }
    }
}

@Composable
private fun LevelHalo(level: StateFlow<Float>) {
    val rms by level.collectAsStateWithLifecycle()
    // Recognisers report roughly -2..10 dB; map that onto a gentle 1.0..1.35 scale.
    val target = 1f + ((rms + 2f) / 12f).coerceIn(0f, 1f) * 0.35f
    val scale by animateFloatAsState(target, label = "level")
    Box(
        modifier = Modifier
            .size(96.dp)
            .scale(scale)
            .clip(CircleShape)
            .background(BrandAccentWarm.copy(alpha = 0.3f)),
    )
}

@Composable
private fun CleanupNote(cleanup: CleanupStatus) {
    val text = when (cleanup) {
        CleanupStatus.Running -> R.string.cleanup_running
        CleanupStatus.Applied -> R.string.cleanup_applied
        CleanupStatus.Failed -> R.string.cleanup_failed
        CleanupStatus.None -> return
    }
    Text(
        stringResource(text),
        style = MaterialTheme.typography.labelMedium,
        color = if (cleanup == CleanupStatus.Failed) {
            MaterialTheme.colorScheme.error
        } else {
            MaterialTheme.colorScheme.onSurfaceVariant
        },
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}

@Composable
private fun ResultActions(state: DictationUiState, snackbar: SnackbarHostState, actions: DictationActions) {
    val dictation = state.dictation
    if (state.cleanup == CleanupStatus.Running) {
        TextButton(onClick = actions.onCancel) { Text(stringResource(R.string.action_skip_cleanup)) }
        return
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val copiedMessage = stringResource(R.string.copied)
    val shareTitle = stringResource(R.string.share_title)
    val (text, final) = when (dictation) {
        is DictationState.Done -> dictation.transcript to true
        is DictationState.Failed -> dictation.unfinishedText to false
        else -> return
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (text.isNotEmpty()) {
            Button(onClick = {
                if (TranscriptOutput.copy(context, text)) scope.launch { snackbar.showSnackbar(copiedMessage) }
            }) {
                Text(stringResource(if (final) R.string.action_copy else R.string.action_copy_unfinished))
            }
            if (final) {
                OutlinedButton(onClick = { TranscriptOutput.share(context, text, shareTitle) }) {
                    Text(stringResource(R.string.action_share))
                }
            }
        }
        if (state.cleanup == CleanupStatus.Applied) {
            TextButton(onClick = actions.onShowOriginal) { Text(stringResource(R.string.action_show_original)) }
        }
        TextButton(onClick = actions.onClear) { Text(stringResource(R.string.action_clear)) }
    }
}

@Composable
private fun statusText(state: DictationUiState): String = when (val dictation = state.dictation) {
    DictationState.Idle -> stringResource(R.string.state_ready)
    is DictationState.Starting -> stringResource(R.string.state_starting)
    is DictationState.Listening -> stringResource(R.string.state_listening)
    is DictationState.Finishing -> if (dictation.mode == RecognitionMode.Cloud) {
        stringResource(R.string.state_transcribing, state.cloudModel.provider.displayName)
    } else {
        stringResource(R.string.state_finishing)
    }
    is DictationState.Done -> stringResource(R.string.state_done)
    is DictationState.Failed -> stringResource(dictation.failure.message())
}

@Composable
private fun ModeAvailability.explanation(languageName: String, state: DictationUiState): String = when (status) {
    ModeStatus.Ready -> if (mode == RecognitionMode.Cloud) {
        stringResource(R.string.privacy_cloud, state.cloudModel.provider.displayName, state.cloudModel.displayName)
    } else {
        stringResource(mode.privacyNote())
    }
    ModeStatus.NeedsKey -> stringResource(
        R.string.status_mode_needs_key,
        state.cloudModel.provider.displayName,
        state.cloudModel.displayName,
    )
    ModeStatus.NeedsDownload -> stringResource(R.string.status_mode_needs_download, languageName)
    ModeStatus.Unverified -> stringResource(R.string.status_mode_unverified, languageName)
    ModeStatus.Downloading -> stringResource(R.string.status_mode_downloading, languageName)
    ModeStatus.LanguageUnsupported -> stringResource(R.string.status_mode_language_unsupported, languageName)
    ModeStatus.RequiresNewerAndroid -> stringResource(R.string.status_mode_requires_android12)
    ModeStatus.NotProvided -> stringResource(
        if (mode == RecognitionMode.OnDevice) {
            R.string.status_mode_not_provided_on_device
        } else {
            R.string.status_mode_not_provided_service
        },
    )
}

@StringRes
internal fun RecognitionMode.label(): Int = when (this) {
    RecognitionMode.OnDevice -> R.string.mode_on_device
    RecognitionMode.SpeechService -> R.string.mode_speech_service
    RecognitionMode.Cloud -> R.string.mode_cloud
}

@StringRes
private fun RecognitionMode.privacyNote(): Int = when (this) {
    RecognitionMode.OnDevice -> R.string.privacy_on_device
    RecognitionMode.SpeechService -> R.string.privacy_speech_service
    RecognitionMode.Cloud -> R.string.privacy_cloud_generic
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
    DictationFailure.Unavailable -> R.string.failure_unavailable
    DictationFailure.InvalidKey -> R.string.failure_invalid_key
    DictationFailure.KeyUnavailable -> R.string.failure_key_unavailable
    DictationFailure.MissingKey -> R.string.failure_missing_key
    DictationFailure.AudioTooLarge -> R.string.failure_audio_too_large
    DictationFailure.UnsupportedAudio -> R.string.failure_unsupported_audio
    DictationFailure.Unknown -> R.string.failure_unknown
}
