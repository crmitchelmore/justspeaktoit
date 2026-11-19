package com.justspeaktoit.android.ui

import android.text.format.DateUtils
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.sync.HistorySyncAvailability
import com.justspeaktoit.android.sync.HistorySyncProblem
import com.justspeaktoit.android.sync.HistorySyncStatus

/** Opt-in iCloud History sync through CloudKit Web Services, as on Windows and Linux. */
@Composable
internal fun HistorySyncSection(status: HistorySyncStatus, actions: SettingsActions) {
    Text(stringResource(R.string.settings_history_sync_note), style = MaterialTheme.typography.bodyMedium)
    val problem = status.problem
    Text(
        historySyncStatusText(status),
        style = MaterialTheme.typography.bodyLarge,
        color = if (problem != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier
            .testTag(AutomationIds.SETTINGS_HISTORY_SYNC_STATUS)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
    if (status.availability != HistorySyncAvailability.Available) return
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (status.signedIn) {
            Button(
                onClick = actions.onSyncHistoryNow,
                enabled = !status.syncing,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_HISTORY_SYNC_NOW),
            ) {
                Text(stringResource(R.string.settings_history_sync_now))
            }
            OutlinedButton(
                onClick = actions.onSignOutOfHistorySync,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_HISTORY_SYNC_SIGN_OUT),
            ) {
                Text(stringResource(R.string.settings_history_sync_sign_out))
            }
        } else {
            Button(
                onClick = actions.onSignInToHistorySync,
                enabled = !status.signingIn,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_HISTORY_SYNC_SIGN_IN),
            ) {
                Text(stringResource(R.string.settings_history_sync_sign_in))
            }
        }
    }
    Text(stringResource(R.string.settings_history_sync_audio_note), style = MaterialTheme.typography.bodySmall)
}

@Composable
private fun historySyncStatusText(status: HistorySyncStatus): String {
    val context = LocalContext.current
    status.problem?.let { return stringResource(problemMessage(it)) }
    val last = status.lastSuccessfulSyncMs
    return when {
        status.availability == HistorySyncAvailability.MissingToken ->
            stringResource(R.string.settings_history_sync_not_configured)
        status.availability == HistorySyncAvailability.Misconfigured ->
            stringResource(R.string.settings_history_sync_misconfigured)
        status.signingIn -> stringResource(R.string.settings_history_sync_signing_in)
        !status.signedIn -> stringResource(R.string.settings_history_sync_off)
        status.syncing -> stringResource(R.string.settings_history_sync_syncing)
        last == null -> stringResource(R.string.settings_history_sync_waiting)
        else -> stringResource(
            R.string.settings_history_sync_synced_at,
            DateUtils.formatDateTime(context, last, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME),
        )
    }
}

@StringRes
private fun problemMessage(problem: HistorySyncProblem): Int = when (problem) {
    HistorySyncProblem.SignInNotOffered -> R.string.history_sync_problem_sign_in_not_offered
    HistorySyncProblem.UntrustedSignInPage -> R.string.history_sync_problem_untrusted_page
    HistorySyncProblem.SignInTimedOut -> R.string.history_sync_problem_sign_in_timed_out
    HistorySyncProblem.CallbackUnavailable -> R.string.history_sync_problem_callback_unavailable
    HistorySyncProblem.BrowserUnavailable -> R.string.history_sync_problem_browser_unavailable
    HistorySyncProblem.SignedOut -> R.string.history_sync_problem_signed_out
    HistorySyncProblem.Network -> R.string.history_sync_problem_network
    HistorySyncProblem.Server -> R.string.history_sync_problem_server
    HistorySyncProblem.ChangesNotSaved -> R.string.history_sync_problem_changes_not_saved
    HistorySyncProblem.Incomplete -> R.string.history_sync_problem_incomplete
    HistorySyncProblem.Storage -> R.string.history_sync_problem_storage
    HistorySyncProblem.Unknown -> R.string.history_sync_problem_unknown
}
