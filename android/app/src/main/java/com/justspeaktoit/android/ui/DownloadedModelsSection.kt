package com.justspeaktoit.android.ui

import android.text.format.Formatter
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.local.DownloadFailure
import com.justspeaktoit.android.local.LocalModelItem
import com.justspeaktoit.android.local.LocalModelsState
import com.justspeaktoit.android.local.ModelInstallState

/**
 * Downloaded Whisper models: size, download state and progress, and Download, Cancel, Remove and Use.
 * Downloads use Wi-Fi unless mobile data is allowed. Choosing Downloaded on the dictation screen uses
 * the model picked here.
 */
@Composable
internal fun DownloadedModelsSection(local: LocalModelsState, sessionActive: Boolean, actions: SettingsActions) {
    Text(stringResource(R.string.settings_downloaded_models_note), style = MaterialTheme.typography.bodyMedium)
    if (!local.runtimeAvailable) {
        Text(
            stringResource(R.string.settings_downloaded_models_unavailable),
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.testTag(AutomationIds.SETTINGS_DOWNLOADED_UNAVAILABLE),
        )
        return
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.SETTINGS_DOWNLOADED_MOBILE_DATA)
            .toggleable(
                value = local.downloadOnMobileData,
                role = Role.Switch,
                onValueChange = actions.onDownloadModelsOnMobileDataChanged,
            ),
    ) {
        Text(stringResource(R.string.settings_downloaded_models_mobile_data), modifier = Modifier.weight(1f))
        Switch(checked = local.downloadOnMobileData, onCheckedChange = null)
    }
    local.models.forEach { item ->
        DownloadedModelRow(item, selected = item.model.catalogId == local.selectedId, sessionActive, actions)
    }
}

@Composable
private fun DownloadedModelRow(
    item: LocalModelItem,
    selected: Boolean,
    sessionActive: Boolean,
    actions: SettingsActions,
) {
    val context = LocalContext.current
    val id = item.model.catalogId
    val size = Formatter.formatShortFileSize(context, item.model.bytes)
    val state = item.state
    val installed = state == ModelInstallState.Installed
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.downloadedModelUse(id))
                .selectable(
                    selected = selected,
                    enabled = installed && !sessionActive,
                    role = Role.RadioButton,
                    onClick = { actions.onChooseDownloadedModel(id) },
                ),
        ) {
            RadioButton(selected = selected, onClick = null, enabled = installed && !sessionActive)
            Column(modifier = Modifier.padding(start = 8.dp)) {
                Text(stringResource(R.string.settings_downloaded_model_name, item.model.displayName, size))
                Text(
                    item.model.summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Text(
            stateText(state, item.model.bytes),
            style = MaterialTheme.typography.bodySmall,
            color = if (state is ModelInstallState.Failed) {
                MaterialTheme.colorScheme.error
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            modifier = Modifier
                .testTag(AutomationIds.downloadedModelState(id))
                .semantics { liveRegion = LiveRegionMode.Polite },
        )
        if (state is ModelInstallState.Downloading && item.model.bytes > 0) {
            LinearProgressIndicator(
                progress = { (state.bytes.toFloat() / item.model.bytes).coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            when (state) {
                is ModelInstallState.Downloading -> OutlinedButton(
                    onClick = { actions.onCancelModelDownload(id) },
                    modifier = Modifier.testTag(AutomationIds.downloadedModelCancel(id)),
                ) { Text(stringResource(R.string.action_cancel)) }
                ModelInstallState.Installed -> Unit
                else -> OutlinedButton(
                    onClick = { actions.onDownloadLocalModel(id) },
                    modifier = Modifier.testTag(AutomationIds.downloadedModelDownload(id)),
                ) { Text(stringResource(downloadLabel(state))) }
            }
            if (installed || state.partialBytes() > 0) {
                TextButton(
                    onClick = { actions.onRemoveLocalModel(id) },
                    enabled = !(selected && sessionActive),
                    modifier = Modifier.testTag(AutomationIds.downloadedModelRemove(id)),
                ) { Text(stringResource(R.string.action_remove)) }
            }
        }
    }
}

@Composable
private fun stateText(state: ModelInstallState, total: Long): String {
    val context = LocalContext.current
    fun size(bytes: Long) = Formatter.formatShortFileSize(context, bytes)
    return when (state) {
        ModelInstallState.Installed -> stringResource(R.string.settings_downloaded_model_installed)
        ModelInstallState.WaitingForWifi -> stringResource(R.string.settings_downloaded_model_waiting_wifi)
        is ModelInstallState.Downloading ->
            stringResource(R.string.settings_downloaded_model_downloading, size(state.bytes), size(total))
        is ModelInstallState.NotDownloaded -> if (state.partialBytes > 0) {
            stringResource(R.string.settings_downloaded_model_paused, size(state.partialBytes), size(total))
        } else {
            stringResource(R.string.settings_downloaded_model_not_downloaded)
        }
        is ModelInstallState.Failed -> stringResource(state.reason.message())
    }
}

@StringRes
private fun downloadLabel(state: ModelInstallState): Int = when {
    state.partialBytes() > 0 -> R.string.action_resume_download
    state is ModelInstallState.Failed -> R.string.action_retry_download
    else -> R.string.action_download
}

private fun ModelInstallState.partialBytes(): Long = when (this) {
    is ModelInstallState.NotDownloaded -> partialBytes
    is ModelInstallState.Failed -> partialBytes
    else -> 0L
}

@StringRes
private fun DownloadFailure.message(): Int = when (this) {
    DownloadFailure.Network -> R.string.download_failure_network
    DownloadFailure.Http -> R.string.download_failure_http
    DownloadFailure.HostNotAllowed -> R.string.download_failure_host
    DownloadFailure.SizeMismatch, DownloadFailure.ChecksumMismatch -> R.string.download_failure_verification
    DownloadFailure.Storage -> R.string.download_failure_storage
    DownloadFailure.Cancelled -> R.string.settings_downloaded_model_not_downloaded
}
