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
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.diagnostics.AndroidIssueEnvironment
import com.justspeaktoit.android.diagnostics.IssueFacts
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryFilter
import com.justspeaktoit.android.history.HistoryInsights
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.output.TranscriptOutput
import com.justspeaktoit.android.readaloud.PronunciationEntry
import com.justspeaktoit.android.readaloud.ReadAloudController
import com.justspeaktoit.android.readaloud.ReadAloudState
import com.justspeaktoit.android.readaloud.VoiceSelection
import com.justspeaktoit.android.sendtomac.SendToMacActivity
import com.justspeaktoit.android.sendtomac.SendToMacState
import java.time.LocalDate
import kotlinx.coroutines.delay

class HistoryActions(
    val onBack: () -> Unit,
    val onRetention: (Retention) -> Unit,
    val onDelete: (String) -> Unit,
    /** Clears History; true keeps the entries that hold a recording. */
    val onClear: (keepRecordings: Boolean) -> Unit,
    val onTranscribe: (String) -> Unit,
    /** Sends the entry's transcript to the paired Mac. */
    val onSendToMac: (HistoryEntry) -> Unit = {},
    val onDismissSendToMac: () -> Unit = {},
)

/** The read-aloud voice and pronunciation dictionary History reads entries with. */
data class HistoryReadAloud(
    val voice: String = VoiceSelection.SYSTEM,
    val pronunciations: List<PronunciationEntry> = emptyList(),
)

/** Which entry the screen's one read-aloud player is reading, and how to read another. */
private class HistoryReader(
    val controller: ReadAloudController,
    val state: ReadAloudState,
    val entryId: String?,
    val read: (HistoryEntry) -> Unit,
)

/** Whether kept audio can be transcribed now, and which entry is being transcribed. */
data class HistoryTranscription(
    val sessionActive: Boolean = false,
    val entryId: String? = null,
    /** Display names of the downloaded models, so their entries are named like cloud ones. */
    val localModelNames: Map<String, String> = emptyMap(),
) {
    val available: Boolean get() = !sessionActive && entryId == null
}

@Composable
fun HistoryScreen(
    entries: List<HistoryEntry>,
    retention: Retention,
    saveFailed: Boolean,
    transcribe: HistoryTranscription,
    actions: HistoryActions,
    sendToMac: SendToMacState = SendToMacState(),
    readAloud: HistoryReadAloud = HistoryReadAloud(),
) {
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    // Filters are view state only: they never change the stored entries.
    var searchText by rememberSaveable { mutableStateOf("") }
    var modelFilter by rememberSaveable { mutableStateOf<String?>(null) }
    var errorsOnly by rememberSaveable { mutableStateOf(false) }
    var fromEpochDay by rememberSaveable { mutableStateOf<Long?>(null) }
    var throughEpochDay by rememberSaveable { mutableStateOf<Long?>(null) }
    val filter = HistoryFilter(
        searchText = searchText,
        model = modelFilter,
        errorsOnly = errorsOnly,
        fromDay = fromEpochDay?.let(LocalDate::ofEpochDay),
        throughDay = throughEpochDay?.let(LocalDate::ofEpochDay),
    )
    val modeLabels = RecognitionMode.entries.associate { it.name to stringResource(it.label()) }
    val modelName: (String) -> String = { key ->
        modeLabels[key] ?: CloudCatalog.findTranscriptionModel(key)?.displayName
            ?: transcribe.localModelNames[key] ?: key
    }
    val models = remember(entries, modeLabels) { HistoryFilter.models(entries).sortedBy(modelName) }
    val visible = remember(entries, filter, modeLabels) { filter.matching(entries, modelName = modelName) }
    val player = remember { HistoryAudioPlayer() }
    DisposableEffect(player) { onDispose { player.stop() } }
    // Nothing plays while the microphone records, or once its entry has gone.
    LaunchedEffect(transcribe.sessionActive, entries) {
        val playing = player.playingPath
        if (transcribe.sessionActive || (playing != null && entries.none { it.audioPath == playing })) player.stop()
    }
    val snackbar = remember { SnackbarHostState() }
    val reader = rememberReadAloudController(snackbar)
    val readerState by reader.state.collectAsStateWithLifecycle()
    var readingId by rememberSaveable { mutableStateOf<String?>(null) }
    // Reading aloud stops while the microphone records, or once its entry, and so its controls, is no
    // longer listed: deleted, or hidden by the search or a filter.
    LaunchedEffect(transcribe.sessionActive, visible) {
        if (transcribe.sessionActive || visible.none { it.id == readingId }) reader.stop()
    }
    val history = HistoryReader(
        controller = reader,
        state = readerState,
        entryId = readingId.takeIf { readerState.active },
        read = { entry ->
            player.stop()
            readingId = entry.id
            reader.speak(entry.text, VoiceSelection.parse(readAloud.voice), readAloud.pronunciations)
        },
    )
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
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
            if (sendToMac.activity.isSendStatus()) {
                item(key = "sendToMacStatus") { SendToMacStatus(sendToMac.activity, actions.onDismissSendToMac) }
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
            } else {
                item(key = "historyFilters") {
                    HistoryFilterBar(filter, models, modelName) { next ->
                        searchText = next.searchText
                        modelFilter = next.model
                        errorsOnly = next.errorsOnly
                        fromEpochDay = next.fromDay?.toEpochDay()
                        throughEpochDay = next.throughDay?.toEpochDay()
                    }
                }
                if (filter.isActive) item(key = "historyFilterSummary") { FilterSummary(visible.size, entries.size) }
            }
            items(visible, key = { it.id }) { entry ->
                HistoryCard(entry, transcribe, player, history, sendToMac, actions)
            }
        }
    }
    if (confirmClear) {
        val hasRecordings = entries.any { it.audioPath != null }
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            text = {
                Text(
                    stringResource(
                        if (hasRecordings) R.string.clear_history_confirm_recordings else R.string.clear_history_confirm,
                    ),
                )
            },
            confirmButton = {
                Row {
                    if (hasRecordings) {
                        TextButton(
                            onClick = {
                                confirmClear = false
                                actions.onClear(true)
                            },
                            modifier = Modifier.testTag(AutomationIds.HISTORY_CLEAR_KEEP_RECORDINGS),
                        ) { Text(stringResource(R.string.action_clear_keep_recordings)) }
                    }
                    TextButton(
                        onClick = {
                            confirmClear = false
                            actions.onClear(false)
                        },
                        modifier = Modifier.testTag(AutomationIds.HISTORY_CLEAR_ALL),
                    ) {
                        Text(stringResource(if (hasRecordings) R.string.action_delete_all else R.string.action_delete))
                    }
                }
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
private fun HistoryCard(
    entry: HistoryEntry,
    transcribe: HistoryTranscription,
    player: HistoryAudioPlayer,
    reader: HistoryReader,
    sendToMac: SendToMacState,
    actions: HistoryActions,
) {
    val context = LocalContext.current
    var reporting by rememberSaveable { mutableStateOf(false) }
    val shareTitle = stringResource(R.string.share_title)
    val failed = entry.status == HistoryStatus.Failed
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = listOfNotNull(
                    DateUtils.getRelativeTimeSpanString(entry.createdAtMs).toString(),
                    sourceLabel(entry, transcribe.localModelNames),
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
            val audio = entry.audioPath
            if (audio != null && player.failedPath == audio) {
                Text(
                    stringResource(R.string.history_play_failed),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
            FlowRow {
                if (audio != null) {
                    val playing = player.playingPath == audio
                    TextButton(
                        onClick = {
                            reader.controller.stop()
                            player.toggle(audio)
                        },
                        enabled = playing || !transcribe.sessionActive,
                        modifier = Modifier.testTag(AutomationIds.historyPlay(entry.id)),
                    ) {
                        Text(stringResource(if (playing) R.string.action_stop_playback else R.string.action_play_recording))
                    }
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
                if (!failed && entry.text.isNotBlank()) {
                    val reading = reader.entryId == entry.id
                    ReadAloudControls(
                        state = if (reading) reader.state else ReadAloudState(),
                        tags = ReadAloudTags(AutomationIds.historyReadAloud(entry.id)),
                        onRead = { reader.read(entry) },
                        controller = reader.controller,
                        readEnabled = !transcribe.sessionActive,
                    )
                }
                if (!failed && entry.text.isNotBlank() && sendToMac.isPaired) {
                    TextButton(
                        onClick = { actions.onSendToMac(entry) },
                        enabled = !sendToMac.isBusy,
                        modifier = Modifier.testTag(AutomationIds.historySendToMac(entry.id)),
                    ) { Text(stringResource(R.string.action_send_to_mac)) }
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

private fun SendToMacActivity.isSendStatus(): Boolean =
    this is SendToMacActivity.Sending || this is SendToMacActivity.Sent || this is SendToMacActivity.SendFailed

/** The last Send to Mac from History, announced as it changes; a success clears itself, as on iOS. */
@Composable
private fun SendToMacStatus(activity: SendToMacActivity, onDismiss: () -> Unit) {
    LaunchedEffect(activity) {
        if (activity is SendToMacActivity.Sent) {
            delay(SENT_STATUS_MS)
            onDismiss()
        }
    }
    val (text, failed) = sendToMacActivityText(activity) ?: return
    Card(modifier = Modifier.fillMaxWidth()) {
        Row(modifier = Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text,
                style = MaterialTheme.typography.bodyMedium,
                color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier
                    .weight(1f)
                    .testTag(AutomationIds.HISTORY_SEND_TO_MAC_STATUS)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
            if (activity !is SendToMacActivity.Sending) {
                IconButton(onClick = onDismiss, modifier = Modifier.testTag(AutomationIds.HISTORY_SEND_TO_MAC_DISMISS)) {
                    Icon(painterResource(R.drawable.ic_close), stringResource(R.string.send_to_mac_dismiss))
                }
            }
        }
    }
}

private const val SENT_STATUS_MS = 4_000L

/** How many entries the search and filters leave, announced as it changes. */
@Composable
private fun FilterSummary(shown: Int, total: Int) {
    Text(
        if (shown == 0) {
            stringResource(R.string.history_filter_no_matches)
        } else {
            pluralStringResource(R.plurals.history_filter_shown, total, shown, total)
        },
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier
            .testTag(AutomationIds.HISTORY_FILTER_SUMMARY)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
}

@Composable
private fun sourceLabel(entry: HistoryEntry, localModelNames: Map<String, String>): String? {
    // Only entries received through History sync carry an origin.
    val origin = entry.originPlatform
    if (origin != null) {
        return stringResource(R.string.history_synced_from, platformName(origin))
    }
    val mode = RecognitionMode.entries.firstOrNull { it.name == entry.mode } ?: return null
    if (mode == RecognitionMode.Cloud) {
        return CloudCatalog.findTranscriptionModel(entry.model)?.displayName
            ?: entry.model
    }
    if (mode == RecognitionMode.Downloaded) {
        entry.model?.let(localModelNames::get)?.let { return it }
    }
    return stringResource(mode.label())
}

@Composable
private fun platformName(origin: String): String = when (origin) {
    "macos" -> stringResource(R.string.history_platform_mac)
    "ios" -> stringResource(R.string.history_platform_ios)
    "windows" -> stringResource(R.string.history_platform_windows)
    "linux" -> stringResource(R.string.history_platform_linux)
    "android" -> stringResource(R.string.history_platform_android)
    else -> origin
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
