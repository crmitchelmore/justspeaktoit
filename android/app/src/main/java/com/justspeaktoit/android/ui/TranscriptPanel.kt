package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.CleanupStatus
import com.justspeaktoit.android.dictation.DictationState
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.output.TranscriptOutput
import kotlinx.coroutines.launch

/** The session status, cleanup progress and transcript text. */
@Composable
internal fun TranscriptCard(state: DictationUiState) {
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
                modifier = Modifier.testTag(AutomationIds.STATUS).semantics { liveRegion = LiveRegionMode.Polite },
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
                modifier = Modifier.testTag(AutomationIds.TRANSCRIPT),
            )
        }
    }
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

/** What can be done with a finished or unfinished transcript: copy, share, show original, clear, read aloud. */
@Composable
internal fun ResultActions(state: DictationUiState, snackbar: SnackbarHostState, actions: DictationActions) {
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
            Button(
                onClick = {
                    if (TranscriptOutput.copy(context, text)) scope.launch { snackbar.showSnackbar(copiedMessage) }
                },
                modifier = Modifier.testTag(AutomationIds.COPY),
            ) {
                Text(stringResource(if (final) R.string.action_copy else R.string.action_copy_unfinished))
            }
            if (final) {
                OutlinedButton(
                    onClick = { TranscriptOutput.share(context, text, shareTitle) },
                    modifier = Modifier.testTag(AutomationIds.SHARE),
                ) {
                    Text(stringResource(R.string.action_share))
                }
            }
        }
        if (state.cleanup == CleanupStatus.Applied) {
            TextButton(onClick = actions.onShowOriginal, modifier = Modifier.testTag(AutomationIds.SHOW_ORIGINAL)) {
                Text(stringResource(R.string.action_show_original))
            }
        }
        TextButton(onClick = actions.onClear, modifier = Modifier.testTag(AutomationIds.CLEAR)) {
            Text(stringResource(R.string.action_clear))
        }
    }
    if (final && text.isNotBlank()) ReadAloudButton(text, snackbar)
}

@Composable
private fun statusText(state: DictationUiState): String = when (val dictation = state.dictation) {
    DictationState.Idle -> stringResource(R.string.state_ready)
    is DictationState.Starting -> stringResource(R.string.state_starting)
    is DictationState.Listening ->
        stringResource(if (state.paused) R.string.state_paused else R.string.state_listening)
    is DictationState.Finishing -> if (dictation.mode == RecognitionMode.Cloud) {
        stringResource(R.string.state_transcribing, state.sessionCloudModel.provider.displayName)
    } else {
        stringResource(R.string.state_finishing)
    }
    is DictationState.Done -> stringResource(R.string.state_done)
    is DictationState.Failed -> stringResource(dictation.failure.message())
}
