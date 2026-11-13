package com.justspeaktoit.android.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.diagnostics.AndroidIssueEnvironment
import com.justspeaktoit.android.diagnostics.IssueFacts
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryInsights
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.output.TranscriptOutput

class HistoryActions(
    val onBack: () -> Unit,
    val onRetention: (Retention) -> Unit,
    val onDelete: (String) -> Unit,
    val onClear: () -> Unit,
    val onTranscribe: (String) -> Unit,
)

/** Whether kept audio can be transcribed now, and which entry is being transcribed. */
data class HistoryTranscription(val sessionActive: Boolean = false, val entryId: String? = null) {
    val available: Boolean get() = !sessionActive && entryId == null
}

@Composable
fun HistoryScreen(
    entries: List<HistoryEntry>,
    retention: Retention,
    saveFailed: Boolean,
    transcribe: HistoryTranscription,
    actions: HistoryActions,
) {
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
            val insights = HistoryInsights.of(entries, System.currentTimeMillis())
            if (insights.dictations > 0) item { InsightsCard(insights) }
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
            items(entries, key = { it.id }) { entry -> HistoryCard(entry, transcribe, actions) }
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

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HistoryCard(entry: HistoryEntry, transcribe: HistoryTranscription, actions: HistoryActions) {
    val context = LocalContext.current
    var reporting by rememberSaveable { mutableStateOf(false) }
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
            if (entry.status == HistoryStatus.Cancelled) {
                Text(stringResource(R.string.history_cancelled), style = MaterialTheme.typography.labelMedium)
                val reason = DictationFailure.entries.firstOrNull { it.name == entry.failure }
                if (reason != null) {
                    Text(
                        stringResource(R.string.history_transcribe_failed, stringResource(reason.message())),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
            if (entry.text.isNotEmpty()) {
                Text(entry.text, style = MaterialTheme.typography.bodyLarge)
            }
            FlowRow {
                if (entry.audioPath != null) {
                    val running = transcribe.entryId == entry.id
                    TextButton(onClick = { actions.onTranscribe(entry.id) }, enabled = transcribe.available) {
                        Text(stringResource(if (running) R.string.history_transcribing else R.string.action_transcribe))
                    }
                }
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
                TextButton(
                    onClick = { reporting = true },
                    modifier = Modifier.testTag(AutomationIds.HISTORY_REPORT_ISSUE),
                ) { Text(stringResource(R.string.action_report_issue)) }
                TextButton(onClick = { actions.onDelete(entry.id) }) { Text(stringResource(R.string.action_delete)) }
            }
        }
    }
    if (reporting) {
        val facts = remember(entry) { IssueFacts.forHistory(entry, AndroidIssueEnvironment.current(context)) }
        IssueReportDialog(facts) { reporting = false }
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

/** Recent dictation totals, the Android counterpart of the Mac's usage insights. */
@Composable
private fun InsightsCard(insights: HistoryInsights) {
    val dictations = pluralStringResource(
        R.plurals.history_insights_dictations, insights.dictations, insights.dictations,
    )
    val words = pluralStringResource(R.plurals.history_insights_words, insights.words, insights.words)
    Card(modifier = Modifier.fillMaxWidth().testTag(AutomationIds.HISTORY_INSIGHTS)) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.history_insights_title), style = MaterialTheme.typography.titleMedium)
            Text(
                stringResource(R.string.history_insights_summary, dictations, words),
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                stringResource(R.string.history_insights_note),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
