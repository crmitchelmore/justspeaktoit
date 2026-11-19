package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.tips.TipJarStatus
import com.justspeaktoit.android.tips.TipJarUiState
import com.justspeaktoit.android.tips.TipMessage

/** The user's telemetry choices as Settings shows them; both off until the user turns them on. */
data class PrivacyChoices(val analytics: Boolean = false, val diagnostics: Boolean = false)

/** A labelled switch row: the whole row toggles, and TalkBack reads one switch with the title as its name. */
@Composable
internal fun ConsentSwitchRow(
    @StringRes title: Int,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange),
    ) {
        Text(
            stringResource(title),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f),
        )
        Switch(checked = checked, onCheckedChange = null)
    }
}

/**
 * The first-run privacy prompt. Both switches start off, and Done or dismissing records exactly what they show,
 * so nothing is collected unless the user turned it on.
 */
@Composable
fun ConsentDialog(onDone: (analytics: Boolean, diagnostics: Boolean) -> Unit) {
    var analytics by rememberSaveable { mutableStateOf(false) }
    var diagnostics by rememberSaveable { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = { onDone(analytics, diagnostics) },
        title = { Text(stringResource(R.string.consent_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.consent_body))
                ConsentSwitchRow(
                    R.string.settings_analytics_title,
                    analytics,
                    { analytics = it },
                    Modifier.testTag(AutomationIds.CONSENT_ANALYTICS),
                )
                Text(stringResource(R.string.settings_analytics_note), style = MaterialTheme.typography.bodySmall)
                ConsentSwitchRow(
                    R.string.settings_diagnostics_title,
                    diagnostics,
                    { diagnostics = it },
                    Modifier.testTag(AutomationIds.CONSENT_DIAGNOSTICS),
                )
                Text(stringResource(R.string.settings_diagnostics_note), style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onDone(analytics, diagnostics) },
                modifier = Modifier.testTag(AutomationIds.CONSENT_DONE),
            ) {
                Text(stringResource(R.string.action_done))
            }
        },
    )
}

/** The tip jar: one button per tier Google Play sells, cheapest first. */
@Composable
internal fun TipJarSection(state: TipJarUiState, onTip: (String) -> Unit) {
    Text(stringResource(R.string.tip_jar_note), style = MaterialTheme.typography.bodyMedium)
    val status = when (state.status) {
        TipJarStatus.Loading -> R.string.tip_jar_loading
        TipJarStatus.Unavailable -> R.string.tip_jar_unavailable
        TipJarStatus.Ready -> null
    }
    if (status != null) {
        Text(
            stringResource(status),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .testTag(AutomationIds.TIP_JAR_STATUS)
                .semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
    state.offers.forEach { offer ->
        OutlinedButton(
            onClick = { onTip(offer.productId) },
            enabled = state.purchasingProductId == null,
            modifier = Modifier.fillMaxWidth().testTag(AutomationIds.tipProduct(offer.productId)),
        ) {
            // Decorative: the tier's name already says what the emoji shows.
            Text(offer.emoji, modifier = Modifier.clearAndSetSemantics {})
            Text(offer.name, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
            if (state.purchasingProductId == offer.productId) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            } else {
                Text(offer.price)
            }
        }
    }
    val message = when (state.message) {
        TipMessage.Thanks -> R.string.tip_jar_thanks
        TipMessage.Pending -> R.string.tip_jar_pending
        TipMessage.Unconfirmed -> R.string.tip_jar_unconfirmed
        TipMessage.Failed -> R.string.tip_jar_failed
        null -> null
    }
    if (message != null) {
        Text(
            stringResource(message),
            color = if (state.message == TipMessage.Failed) MaterialTheme.colorScheme.error else Color.Unspecified,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}
