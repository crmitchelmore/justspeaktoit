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
import com.justspeaktoit.android.local.CleanupModelsState
import com.justspeaktoit.android.local.DownloadFailure
import com.justspeaktoit.android.local.LocalModelItem
import com.justspeaktoit.android.local.LocalModelsState
import com.justspeaktoit.android.local.ModelInstallState
import com.justspeaktoit.android.local.PinnedModel

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
    val rowActions = DownloadedModelActions(
        use = actions.onChooseDownloadedModel,
        download = actions.onDownloadLocalModel,
        cancel = actions.onCancelModelDownload,
        remove = actions.onRemoveLocalModel,
    )
    local.models.forEach { item ->
        DownloadedModelRow(item, selected = item.model.catalogId == local.selectedId, sessionActive, rowActions)
    }
}

/**
 * Downloaded cleanup models (llama.cpp): the same rows as Whisper's, where Use makes the model clean up
 * every recording in place of the cleanup model picked above ([otherLabel], a cloud model or Gemini
 * Nano), with the cleanup prompt as its instructions. There is no fallback: if the model fails, the
 * original transcript is kept.
 */
@Composable
internal fun DownloadedCleanupSection(
    local: CleanupModelsState,
    cleanupEnabled: Boolean,
    sessionActive: Boolean,
    otherLabel: String,
    actions: SettingsActions,
) {
    Text(stringResource(R.string.settings_downloaded_cleanup_note), style = MaterialTheme.typography.bodyMedium)
    if (!local.runtimeAvailable) {
        Text(
            stringResource(R.string.settings_downloaded_cleanup_unavailable),
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.testTag(AutomationIds.SETTINGS_DOWNLOADED_CLEANUP_UNAVAILABLE),
        )
        // A saved choice can still be cleared, so cleanup goes back to the picked model.
        if (local.selectedId != null) UseOtherCleanupButton(sessionActive, otherLabel, actions)
        return
    }
    val rowActions = DownloadedModelActions(
        use = { actions.onChooseLocalCleanupModel(it) },
        download = actions.onDownloadCleanupModel,
        cancel = actions.onCancelCleanupModelDownload,
        remove = actions.onRemoveCleanupModel,
    )
    local.models.forEach { item ->
        DownloadedModelRow(item, selected = item.model.catalogId == local.selectedId, sessionActive, rowActions)
    }
    val selected = local.selectedId ?: return
    if (cleanupEnabled && !local.ready) {
        Text(
            stringResource(
                R.string.settings_downloaded_cleanup_not_ready,
                local.displayName(selected) ?: selected,
            ),
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier
                .testTag(AutomationIds.SETTINGS_DOWNLOADED_CLEANUP_NOT_READY)
                .semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
    UseOtherCleanupButton(sessionActive, otherLabel, actions)
}

@Composable
private fun UseOtherCleanupButton(sessionActive: Boolean, otherLabel: String, actions: SettingsActions) {
    OutlinedButton(
        onClick = { actions.onChooseLocalCleanupModel(null) },
        enabled = !sessionActive,
        modifier = Modifier.testTag(AutomationIds.SETTINGS_DOWNLOADED_CLEANUP_USE_OTHER),
    ) { Text(stringResource(R.string.settings_downloaded_cleanup_use_other, otherLabel)) }
}

/** The downloaded cleanup models the cleanup picker's **On this phone** section offers, and choosing one. */
class DownloadedCleanupChoices(
    val state: CleanupModelsState = CleanupModelsState(),
    val onChoose: (String) -> Unit = {},
)

/**
 * The downloaded cleanup models in the cleanup picker, under Gemini Nano: each downloaded one can be
 * chosen; models still to download are reached from Downloaded cleanup models in Settings. Nothing is
 * shown where the phone offers no downloaded cleanup models.
 */
@Composable
internal fun DownloadedCleanupPickerRows(choices: DownloadedCleanupChoices) {
    val local = choices.state
    if (local.names.isEmpty()) return
    if (!local.runtimeAvailable) {
        PickerNote(stringResource(R.string.settings_downloaded_cleanup_unavailable))
        return
    }
    val installed = local.models.filter { it.state == ModelInstallState.Installed }
    if (installed.isEmpty()) {
        PickerNote(stringResource(R.string.cleanup_picker_downloaded_none))
        return
    }
    installed.forEach { item ->
        val id = item.model.catalogId
        val isSelected = id == local.selectedId
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.CLEANUP_PICKER.model(id))
                .selectable(selected = isSelected, role = Role.RadioButton, onClick = { choices.onChoose(id) })
                .padding(vertical = 8.dp),
        ) {
            RadioButton(selected = isSelected, onClick = null)
            Column(modifier = Modifier.padding(start = 12.dp).weight(1f)) {
                Text(item.model.displayName, style = MaterialTheme.typography.bodyLarge)
                Text(
                    stringResource(R.string.cleanup_picker_downloaded_model),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun PickerNote(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.CLEANUP_PICKER_DOWNLOADED_STATUS)
            .padding(vertical = 8.dp),
    )
}

/** What a [DownloadedModelRow]'s controls do, each given the model's catalogue ID. */
internal class DownloadedModelActions(
    val use: (String) -> Unit,
    val download: (String) -> Unit,
    val cancel: (String) -> Unit,
    val remove: (String) -> Unit,
)

/**
 * One pinned model (Whisper or cleanup): its name, size and state, download progress, and Use, Download,
 * Cancel and Remove. Tags are keyed by the catalogue ID, which is unique across both lists.
 */
@Composable
internal fun DownloadedModelRow(
    item: LocalModelItem<PinnedModel>,
    selected: Boolean,
    sessionActive: Boolean,
    actions: DownloadedModelActions,
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
                    onClick = { actions.use(id) },
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
                    onClick = { actions.cancel(id) },
                    modifier = Modifier.testTag(AutomationIds.downloadedModelCancel(id)),
                ) { Text(stringResource(R.string.action_cancel)) }
                ModelInstallState.Installed -> Unit
                else -> OutlinedButton(
                    onClick = { actions.download(id) },
                    modifier = Modifier.testTag(AutomationIds.downloadedModelDownload(id)),
                ) { Text(stringResource(downloadLabel(state))) }
            }
            if (installed || state.partialBytes() > 0) {
                TextButton(
                    onClick = { actions.remove(id) },
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
