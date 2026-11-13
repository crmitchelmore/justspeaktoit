package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.dictation.RecognitionMode
import kotlinx.coroutines.flow.StateFlow

// The dictation screen: header, mode picker (ModeSection.kt), transcript and its
// actions (TranscriptPanel.kt) and the record button (RecordControls.kt).

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
    /** Makes a profile active, or none with null; applies from the next session. */
    val onChooseProfile: (String?) -> Unit = {},
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
            DictationTopBar(sessionActive = state.dictation.isActive, actions = actions)
            ProfileChooser(state.profiles, state.profile, state.dictation.isActive, actions.onChooseProfile)
            ModeSection(state, actions)
            TranscriptCard(state)
            PermissionNotice(permission, actions)
            RecordControls(state, level, actions)
            ResultActions(state, snackbar, actions)
        }
    }
    if (state.sharedAudio != null) SharedAudioDialog(state, actions)
}

@Composable
private fun DictationTopBar(sessionActive: Boolean, actions: DictationActions) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = stringResource(R.string.app_name),
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
        )
        IconButton(
            onClick = actions.onShowHistory,
            enabled = !sessionActive,
            modifier = Modifier.testTag(AutomationIds.OPEN_HISTORY),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_history),
                contentDescription = stringResource(R.string.history_title),
            )
        }
        // Settings stays open during a session so its microphone and request can be released there.
        IconButton(
            onClick = actions.onShowSettings,
            modifier = Modifier.testTag(AutomationIds.OPEN_SETTINGS),
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_settings),
                contentDescription = stringResource(R.string.settings_title),
            )
        }
    }
}

@Composable
private fun SharedAudioDialog(state: DictationUiState, actions: DictationActions) {
    AlertDialog(
        onDismissRequest = actions.onDismissSharedAudio,
        title = { Text(stringResource(R.string.shared_audio_title)) },
        text = {
            Text(
                stringResource(
                    R.string.shared_audio_body,
                    state.sessionCloudModel.provider.displayName,
                    state.sessionCloudModel.displayName,
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
