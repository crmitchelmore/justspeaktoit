package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.transfer.ConfigTransferState
import com.justspeaktoit.android.transfer.ImportPreview
import com.justspeaktoit.android.transfer.TransferCategory
import com.justspeaktoit.android.transfer.TransferOutcome
import java.text.DateFormat
import java.util.Date

private const val SHOWN_NOTICES = 8

/**
 * Exports the configuration archive the Mac and iPhone also read, and imports one after showing
 * what it would change. API keys go either way only when the user turns that on.
 */
@Composable
internal fun ConfigTransferSection(state: ConfigTransferState, dictating: Boolean, actions: SettingsActions) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.settings_transfer_note), style = MaterialTheme.typography.bodyMedium)
        ConsentSwitchRow(
            R.string.settings_transfer_export_keys,
            state.exportCredentials,
            actions.onExportCredentialsChanged,
            Modifier.testTag(AutomationIds.SETTINGS_TRANSFER_EXPORT_KEYS),
        )
        if (state.exportCredentials) {
            Text(
                stringResource(R.string.settings_transfer_export_keys_warning),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = actions.onExportConfiguration,
                enabled = !state.busy,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_TRANSFER_EXPORT),
            ) {
                Text(stringResource(R.string.settings_transfer_export))
            }
            OutlinedButton(
                onClick = actions.onImportConfiguration,
                enabled = !state.busy && !dictating,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_TRANSFER_IMPORT),
            ) {
                Text(stringResource(R.string.settings_transfer_import))
            }
        }
        TransferStatus(state, dictating)
        state.preview?.let { ImportPreviewCard(it, state, dictating, actions) }
    }
}

@Composable
private fun TransferStatus(state: ConfigTransferState, dictating: Boolean) {
    val message = when {
        state.busy -> stringResource(R.string.settings_transfer_working)
        state.preview != null && dictating -> stringResource(R.string.transfer_stop_dictating)
        else -> when (state.outcome) {
            TransferOutcome.Exported -> stringResource(R.string.settings_transfer_exported)
            TransferOutcome.ExportFailed -> stringResource(R.string.settings_transfer_export_failed)
            TransferOutcome.Imported -> stringResource(R.string.settings_transfer_imported)
            TransferOutcome.ImportFailed -> stringResource(R.string.settings_transfer_import_failed)
            TransferOutcome.Unreadable -> listOfNotNull(
                stringResource(R.string.settings_transfer_unreadable),
                state.detail,
            ).joinToString(" ")
            null -> null
        }
    } ?: return
    val failed = state.outcome in setOf(
        TransferOutcome.ExportFailed,
        TransferOutcome.ImportFailed,
        TransferOutcome.Unreadable,
    )
    Text(
        message,
        style = MaterialTheme.typography.bodyMedium,
        color = if (failed && !state.busy) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier
            .testTag(AutomationIds.SETTINGS_TRANSFER_STATUS)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
}

@Composable
private fun ImportPreviewCard(
    preview: ImportPreview,
    state: ConfigTransferState,
    dictating: Boolean,
    actions: SettingsActions,
) {
    val created = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(preview.createdAtMs))
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth().testTag(AutomationIds.SETTINGS_TRANSFER_PREVIEW),
    ) {
        Text(
            stringResource(R.string.transfer_preview_title, created),
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.semantics { heading() },
        )
        preview.categories.forEach { category ->
            Column {
                Text(stringResource(categoryTitle(category.category)), style = MaterialTheme.typography.bodyLarge)
                Text(
                    stringResource(
                        R.string.transfer_preview_counts,
                        category.added,
                        category.updated,
                        category.unchanged,
                        category.skipped,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (preview.credentials > 0) {
            ConsentSwitchRow(
                R.string.transfer_import_keys,
                state.importCredentials,
                actions.onImportCredentialsChanged,
                Modifier.testTag(AutomationIds.SETTINGS_TRANSFER_IMPORT_KEYS),
            )
            Text(
                stringResource(R.string.transfer_import_keys_note, preview.credentials),
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        preview.notices.take(SHOWN_NOTICES).forEach { notice ->
            Text(notice, style = MaterialTheme.typography.bodySmall)
        }
        val hidden = preview.notices.size - SHOWN_NOTICES
        if (hidden > 0) {
            Text(
                pluralStringResource(R.plurals.transfer_more_notices, hidden, hidden),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        if (!preview.hasChanges) {
            Text(stringResource(R.string.transfer_nothing), style = MaterialTheme.typography.bodyMedium)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = actions.onApplyConfigurationImport,
                enabled = preview.hasChanges && !state.busy && !dictating,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_TRANSFER_APPLY),
            ) {
                Text(stringResource(R.string.transfer_apply))
            }
            TextButton(
                onClick = actions.onDismissConfiguration,
                enabled = !state.busy,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_TRANSFER_CANCEL),
            ) {
                Text(stringResource(R.string.transfer_cancel))
            }
        }
    }
}

@StringRes
private fun categoryTitle(category: TransferCategory): Int = when (category) {
    TransferCategory.Settings -> R.string.transfer_category_settings
    TransferCategory.History -> R.string.transfer_category_history
    TransferCategory.Recordings -> R.string.transfer_category_recordings
    TransferCategory.Credentials -> R.string.transfer_category_credentials
    TransferCategory.Profiles -> R.string.transfer_category_profiles
    TransferCategory.Vocabulary -> R.string.transfer_category_vocabulary
    TransferCategory.Connections -> R.string.transfer_category_connections
    TransferCategory.Models -> R.string.transfer_category_models
}
