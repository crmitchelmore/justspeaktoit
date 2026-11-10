package com.justspeaktoit.android.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.output.TranscriptOutput

class HistoryActions(
    val onBack: () -> Unit,
    val onRetention: (Retention) -> Unit,
    val onDelete: (String) -> Unit,
    val onClear: () -> Unit,
)

@Composable
fun HistoryScreen(entries: List<HistoryEntry>, retention: Retention, saveFailed: Boolean, actions: HistoryActions) {
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    Scaffold { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = actions.onBack, modifier = Modifier.testTag(AutomationIds.HISTORY_BACK)) {
                        Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.action_back))
                    }
                    Text(
                        stringResource(R.string.history_title),
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f),
                    )
                    if (entries.isNotEmpty()) {
                        TextButton(
                            onClick = { confirmClear = true },
                            modifier = Modifier.testTag(AutomationIds.HISTORY_CLEAR),
                        ) {
                            Text(stringResource(R.string.action_clear_history))
                        }
                    }
                }
            }
            item { RetentionPicker(retention, actions.onRetention) }
            item {
                Text(
                    stringResource(R.string.history_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (saveFailed) {
                item {
                    Text(stringResource(R.string.history_save_failed), color = MaterialTheme.colorScheme.error)
                }
            }
            if (entries.isEmpty()) {
                item {
                    Text(
                        stringResource(
                            if (retention == Retention.Off) R.string.history_empty_off else R.string.history_empty,
                        ),
                        style = MaterialTheme.typography.bodyLarge,
                    )
                }
            }
            items(entries, key = { it.id }) { entry -> HistoryCard(entry, actions) }
        }
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            text = { Text(stringResource(R.string.clear_history_confirm)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmClear = false
                    actions.onClear()
                }) { Text(stringResource(R.string.action_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text(stringResource(R.string.action_cancel)) }
            },
        )
    }
}

@Composable
private fun RetentionPicker(retention: Retention, onRetention: (Retention) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.history_keep), style = MaterialTheme.typography.labelLarge)
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            Retention.entries.forEachIndexed { index, option ->
                SegmentedButton(
                    selected = option == retention,
                    onClick = { onRetention(option) },
                    shape = SegmentedButtonDefaults.itemShape(index, Retention.entries.size),
                ) {
                    Text(
                        stringResource(
                            when (option) {
                                Retention.Off -> R.string.retention_off
                                Retention.Week -> R.string.retention_week
                                Retention.Month -> R.string.retention_month
                                Retention.Forever -> R.string.retention_forever
                            },
                        ),
                    )
                }
            }
        }
    }
}

@Composable
private fun HistoryCard(entry: HistoryEntry, actions: HistoryActions) {
    val context = LocalContext.current
    val shareTitle = stringResource(R.string.share_title)
    val failed = entry.status == HistoryStatus.Failed
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = listOfNotNull(
                    DateUtils.getRelativeTimeSpanString(entry.createdAtMs).toString(),
                    sourceLabel(entry),
                    if (entry.cleanedUp) stringResource(R.string.history_cleaned) else null,
                ).joinToString(" · "),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (failed) {
                val reason = DictationFailure.entries.firstOrNull { it.name == entry.failure } ?: DictationFailure.Unknown
                Text(
                    stringResource(R.string.history_failed, stringResource(reason.message())),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.error,
                )
                if (entry.text.isNotEmpty()) {
                    Text(stringResource(R.string.unfinished_label), style = MaterialTheme.typography.labelSmall)
                }
            }
            if (entry.text.isNotEmpty()) {
                Text(entry.text, style = MaterialTheme.typography.bodyLarge)
            }
            Row {
                if (entry.text.isNotEmpty()) {
                    TextButton(onClick = { TranscriptOutput.copy(context, entry.text) }) {
                        Text(stringResource(if (failed) R.string.action_copy_unfinished else R.string.action_copy))
                    }
                    if (!failed) {
                        TextButton(onClick = { TranscriptOutput.share(context, entry.text, shareTitle) }) {
                            Text(stringResource(R.string.action_share))
                        }
                    }
                }
                TextButton(onClick = { actions.onDelete(entry.id) }) { Text(stringResource(R.string.action_delete)) }
            }
        }
    }
}

@Composable
private fun sourceLabel(entry: HistoryEntry): String? {
    val mode = RecognitionMode.entries.firstOrNull { it.name == entry.mode } ?: return null
    if (mode == RecognitionMode.Cloud) {
        return CloudCatalog.transcriptionModels.firstOrNull { it.catalogId == entry.model }?.displayName
            ?: entry.model
    }
    return stringResource(mode.label())
}
