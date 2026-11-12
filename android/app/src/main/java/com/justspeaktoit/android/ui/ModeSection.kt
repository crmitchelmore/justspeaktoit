package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.dictation.ModeAvailability
import com.justspeaktoit.android.dictation.ModeStatus
import com.justspeaktoit.android.dictation.RecognitionMode
import java.util.Locale

/** Picks the recognition mode and explains where audio goes, or what the mode still needs. */
@Composable
internal fun ModeSection(state: DictationUiState, actions: DictationActions) {
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
private fun RecognitionMode.privacyNote(): Int = when (this) {
    RecognitionMode.OnDevice -> R.string.privacy_on_device
    RecognitionMode.SpeechService -> R.string.privacy_speech_service
    RecognitionMode.Cloud -> R.string.privacy_cloud_generic
}
