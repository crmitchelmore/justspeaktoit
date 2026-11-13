package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.corrections.AutoCorrectionCandidate
import com.justspeaktoit.android.corrections.AutoCorrectionLearningPolicy

/**
 * Corrections the keyboard learned from the user's edits, like the Mac's Auto-corrections section:
 * whether to learn, how many edits make a correction, and the suggestions to add or dismiss now.
 */
@Composable
internal fun LearnedCorrections(
    enabled: Boolean,
    threshold: Int,
    candidates: List<AutoCorrectionCandidate>,
    actions: SettingsActions,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.LEARNED_CORRECTIONS_TOGGLE)
                .toggleable(
                    value = enabled,
                    role = Role.Switch,
                    onValueChange = actions.onLearnCorrectionsChanged,
                ),
        ) {
            Text(
                stringResource(R.string.learned_corrections_toggle),
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f),
            )
            Switch(checked = enabled, onCheckedChange = null)
        }
        Text(stringResource(R.string.learned_corrections_note), style = MaterialTheme.typography.bodyMedium)
        if (enabled) ThresholdStepper(threshold, actions.onCorrectionThresholdChanged)
        Text(
            stringResource(R.string.learned_corrections_suggestions),
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.semantics { heading() },
        )
        if (candidates.isEmpty()) {
            Text(
                stringResource(R.string.learned_corrections_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            candidates.forEachIndexed { index, candidate -> CandidateRow(index, candidate, actions) }
            TextButton(
                onClick = actions.onClearCorrectionSuggestions,
                modifier = Modifier.testTag(AutomationIds.LEARNED_CORRECTIONS_CLEAR),
            ) {
                Text(stringResource(R.string.learned_corrections_clear))
            }
        }
    }
}

@Composable
private fun ThresholdStepper(threshold: Int, onChange: (Int) -> Unit) {
    val range = AutoCorrectionLearningPolicy.PROMOTION_THRESHOLD_RANGE
    val fewer = stringResource(R.string.learned_corrections_fewer)
    val more = stringResource(R.string.learned_corrections_more)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            pluralStringResource(R.plurals.learned_corrections_threshold, threshold, threshold),
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f),
        )
        OutlinedButton(
            onClick = { onChange(threshold - 1) },
            enabled = threshold > range.first,
            modifier = Modifier
                .testTag(AutomationIds.LEARNED_CORRECTIONS_FEWER)
                .semantics { contentDescription = fewer },
        ) {
            Text("−")
        }
        OutlinedButton(
            onClick = { onChange(threshold + 1) },
            enabled = threshold < range.last,
            modifier = Modifier
                .testTag(AutomationIds.LEARNED_CORRECTIONS_MORE)
                .semantics { contentDescription = more },
        ) {
            Text("+")
        }
    }
}

@Composable
private fun CandidateRow(index: Int, candidate: AutoCorrectionCandidate, actions: SettingsActions) {
    val (original, corrected) = candidate.original to candidate.corrected
    val accept = stringResource(R.string.learned_corrections_accept_description, original, corrected)
    val dismiss = stringResource(R.string.learned_corrections_dismiss_description, original, corrected)
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                stringResource(R.string.learned_corrections_pair, original, corrected),
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                pluralStringResource(R.plurals.learned_corrections_seen, candidate.seenCount, candidate.seenCount),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        TextButton(
            onClick = { actions.onAcceptCorrection(candidate.id) },
            modifier = Modifier
                .testTag(AutomationIds.learnedCorrectionAccept(index))
                .semantics { contentDescription = accept },
        ) {
            Text(stringResource(R.string.learned_corrections_accept))
        }
        TextButton(
            onClick = { actions.onDismissCorrection(candidate.id) },
            modifier = Modifier
                .testTag(AutomationIds.learnedCorrectionDismiss(index))
                .semantics { contentDescription = dismiss },
        ) {
            Text(stringResource(R.string.learned_corrections_dismiss))
        }
    }
}
