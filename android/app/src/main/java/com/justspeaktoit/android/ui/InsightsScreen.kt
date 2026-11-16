package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.SpeechInsightsDefinitions
import com.justspeaktoit.android.history.SpeechInsightsEngine
import com.justspeaktoit.android.history.SpeechInsightsSummary
import com.justspeaktoit.android.history.SpeechSession
import com.justspeaktoit.android.history.TermCount
import com.justspeaktoit.android.history.UsageInsights
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Usage insights worked out on this phone from History: the usage totals plus SpeakCore's speech
 * insights (phrases, fillers, pace and records), with the same definitions and numbers as the Mac and
 * iPhone dashboards for the same History. Nothing is sent anywhere.
 */
@Composable
fun InsightsScreen(entries: List<HistoryEntry>, onBack: () -> Unit) {
    val context = LocalContext.current
    val definitions = remember {
        context.assets.open(SpeechInsightsDefinitions.ASSET).bufferedReader().use { it.readText() }
            .let(SpeechInsightsDefinitions::parse)
    }
    val usage = remember(entries) { UsageInsights.of(entries) }
    val summary by produceState<SpeechInsightsSummary?>(null, entries, definitions) {
        value = withContext(Dispatchers.Default) {
            SpeechInsightsEngine.summarize(entries.mapNotNull(SpeechSession::from), definitions)
        }
    }
    Scaffold(modifier = Modifier.testTag(AutomationIds.INSIGHTS_SCREEN)) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onBack, modifier = Modifier.testTag(AutomationIds.INSIGHTS_BACK)) {
                        Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.action_back))
                    }
                    Text(
                        stringResource(R.string.insights_title),
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            item { UsageCard(usage) }
            val current = summary
            when {
                current == null -> item {
                    Text(
                        stringResource(R.string.insights_loading),
                        modifier = Modifier.testTag(AutomationIds.INSIGHTS_LOADING),
                    )
                }
                current.sessionsAnalyzed == 0 -> item {
                    Text(
                        stringResource(R.string.insights_empty),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag(AutomationIds.INSIGHTS_EMPTY),
                    )
                }
                else -> {
                    item { PhrasesCard(current) }
                    item { FillersCard(current) }
                    item { PaceCard(current) }
                    item { RecordsCard(current) }
                }
            }
            item {
                Text(
                    stringResource(R.string.insights_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun UsageCard(usage: UsageInsights) {
    InsightsSection(R.string.insights_usage_title, AutomationIds.INSIGHTS_USAGE) {
        StatRow(R.string.insights_sessions, usage.sessions.toString())
        StatRow(R.string.insights_errors, usage.sessionsWithErrors.toString())
        StatRow(R.string.insights_recording_time, formatInsightsDuration(usage.recordingSeconds))
        StatRow(R.string.insights_average_length, formatInsightsDuration(usage.averageSessionSeconds))
        StatRow(R.string.insights_words, usage.words.toString())
    }
}

@Composable
private fun PhrasesCard(summary: SpeechInsightsSummary) {
    InsightsSection(R.string.insights_phrases_title, AutomationIds.INSIGHTS_PHRASES) {
        Terms(summary.topBigrams.take(5) + summary.topTrigrams.take(3), R.string.insights_phrases_empty)
    }
}

@Composable
private fun FillersCard(summary: SpeechInsightsSummary) {
    val locale = LocalConfiguration.current.locales[0]
    InsightsSection(R.string.insights_fillers_title, AutomationIds.INSIGHTS_FILLERS) {
        StatRow(
            R.string.insights_fillers_rate,
            String.format(locale, "%.1f", summary.fillerRatePer1kWords),
        )
        Terms(summary.topFillers, R.string.insights_fillers_empty)
        if (summary.fillerTrend.size > 1) {
            Text(
                stringResource(R.string.insights_fillers_trend),
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.padding(top = 8.dp),
            )
            summary.fillerTrend.forEach { point ->
                Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}) {
                    Text(stringResource(R.string.insights_week_of, point.weekStart.toString()), Modifier.weight(1f))
                    Text(String.format(locale, "%.1f", point.ratePer1kWords))
                }
            }
        }
    }
}

@Composable
private fun PaceCard(summary: SpeechInsightsSummary) {
    val pace = summary.pace
    InsightsSection(R.string.insights_pace_title, AutomationIds.INSIGHTS_PACE) {
        if (pace.sessionsMeasured == 0) {
            Text(stringResource(R.string.insights_pace_empty), color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            StatRow(R.string.insights_pace_average, stringResource(R.string.insights_wpm, pace.averageWpm.roundToInt()))
            StatRow(R.string.insights_pace_median, stringResource(R.string.insights_wpm, pace.medianWpm.roundToInt()))
            pace.distribution.forEach { bucket ->
                Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}) {
                    Text(stringResource(R.string.insights_pace_bucket, bucket.label), Modifier.weight(1f))
                    Text(bucket.count.toString())
                }
            }
            Text(
                stringResource(R.string.insights_pace_note, pace.sessionsMeasured),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun RecordsCard(summary: SpeechInsightsSummary) {
    InsightsSection(R.string.insights_records_title, AutomationIds.INSIGHTS_RECORDS) {
        StatRow(R.string.insights_words_all_time, summary.totalWords.toString())
        StatRow(R.string.insights_sessions_analysed, summary.sessionsAnalyzed.toString())
        StatRow(
            R.string.insights_longest_session,
            formatInsightsDuration(summary.longestSession?.durationSeconds ?: 0.0),
        )
    }
}

@Composable
private fun InsightsSection(title: Int, tag: String, content: @Composable () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth().testTag(tag)) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

@Composable
private fun StatRow(label: Int, value: String) {
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}) {
        Text(stringResource(label), Modifier.weight(1f))
        Text(value, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Terms(terms: List<TermCount>, empty: Int) {
    if (terms.isEmpty()) {
        Text(stringResource(empty), color = MaterialTheme.colorScheme.onSurfaceVariant)
    } else {
        terms.forEach { term ->
            Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}) {
                Text(term.term, Modifier.weight(1f))
                Text(term.count.toString())
            }
        }
    }
}

/** The Mac and iPhone History headers' duration format: "2m 5s", or "45s" under a minute. */
internal fun formatInsightsDuration(seconds: Double): String {
    val whole = seconds.toInt()
    val minutes = whole / 60
    return if (minutes > 0) "${minutes}m ${whole % 60}s" else "${whole % 60}s"
}
