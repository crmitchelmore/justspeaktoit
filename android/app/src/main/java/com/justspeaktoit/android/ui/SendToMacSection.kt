package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.sendtomac.SendToMacActivity
import com.justspeaktoit.android.sendtomac.SendToMacFailure
import com.justspeaktoit.android.sendtomac.SendToMacState

/**
 * Settings › Send to Mac: the paired Mac, the Macs found nearby, pairing and forgetting, as iOS's
 * Settings › Sync & Transfer › Send to Mac.
 */
@Composable
internal fun SendToMacSection(state: SendToMacState, actions: SettingsActions) {
    var pairingMac by rememberSaveable { mutableStateOf<String?>(null) }
    var confirmingForget by rememberSaveable { mutableStateOf(false) }
    val paired = state.pairedMacName

    // Browse only while unpaired and on screen, as iOS does.
    DisposableEffect(paired == null) {
        if (paired == null) actions.onStartMacDiscovery()
        onDispose { actions.onStopMacDiscovery() }
    }

    Text(
        if (paired != null) stringResource(R.string.send_to_mac_paired, paired) else stringResource(R.string.send_to_mac_not_paired),
        style = MaterialTheme.typography.bodyLarge,
        modifier = Modifier
            .testTag(AutomationIds.SETTINGS_SEND_TO_MAC_PAIRED_MAC)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
    if (paired != null) {
        OutlinedButton(
            onClick = { confirmingForget = true },
            enabled = !state.isBusy,
            modifier = Modifier.testTag(AutomationIds.SETTINGS_SEND_TO_MAC_FORGET),
        ) {
            Text(stringResource(R.string.send_to_mac_forget))
        }
    } else {
        state.nearbyMacs.forEachIndexed { index, mac ->
            OutlinedButton(
                onClick = {
                    actions.onClearSendToMacActivity()
                    pairingMac = mac
                },
                enabled = !state.isBusy,
                modifier = Modifier.testTag(AutomationIds.sendToMacPair(index)),
            ) {
                Text(stringResource(R.string.send_to_mac_pair_with, mac))
            }
        }
        when {
            state.discoveryFailed -> Text(
                stringResource(R.string.send_to_mac_discovery_failed),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .testTag(AutomationIds.SETTINGS_SEND_TO_MAC_DISCOVERY_ERROR)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
            state.nearbyMacs.isEmpty() -> Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_SEND_TO_MAC_SEARCHING),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Text(stringResource(R.string.send_to_mac_searching), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
    // A pairing in progress or its failure shows in the pairing dialog instead.
    if (pairingMac == null) {
        sendToMacActivityText(state.activity)?.let { (text, failed) ->
            Text(
                text,
                style = MaterialTheme.typography.bodyMedium,
                color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier
                    .testTag(AutomationIds.SETTINGS_SEND_TO_MAC_ACTIVITY)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
    }
    Text(stringResource(R.string.settings_send_to_mac_note), style = MaterialTheme.typography.bodySmall)

    pairingMac?.let { mac ->
        SendToMacPairingDialog(mac, state, actions) { pairingMac = null }
    }
    if (confirmingForget && paired != null) {
        AlertDialog(
            onDismissRequest = { confirmingForget = false },
            title = { Text(stringResource(R.string.send_to_mac_forget_title, paired)) },
            text = { Text(stringResource(R.string.send_to_mac_forget_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingForget = false
                        actions.onForgetMac()
                    },
                    modifier = Modifier.testTag(AutomationIds.SETTINGS_SEND_TO_MAC_FORGET_CONFIRM),
                ) {
                    Text(stringResource(R.string.send_to_mac_forget_confirm), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { confirmingForget = false },
                    modifier = Modifier.testTag(AutomationIds.SETTINGS_SEND_TO_MAC_FORGET_CANCEL),
                ) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
}

/** Asks for the six-digit code [mac] shows and pairs with it; closes once paired. */
@Composable
private fun SendToMacPairingDialog(mac: String, state: SendToMacState, actions: SettingsActions, onClose: () -> Unit) {
    var code by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(state.pairedMacName) {
        if (state.pairedMacName == mac) onClose()
    }
    val pairing = state.activity is SendToMacActivity.Pairing
    val canPair = !state.isBusy && code.count { it in '0'..'9' } == PAIRING_CODE_DIGITS
    val pair = { if (canPair) actions.onPairWithMac(mac, code) }
    AlertDialog(
        onDismissRequest = { if (!pairing) onClose() },
        title = { Text(stringResource(R.string.send_to_mac_pairing_title, mac)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = code,
                    onValueChange = { next ->
                        code = next.filter { it in '0'..'9' || it.isWhitespace() }.take(PAIRING_CODE_FIELD_LIMIT)
                    },
                    label = { Text(stringResource(R.string.send_to_mac_pairing_code)) },
                    singleLine = true,
                    enabled = !pairing,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { pair() }),
                    modifier = Modifier.fillMaxWidth().testTag(AutomationIds.SEND_TO_MAC_PAIRING_CODE),
                )
                Text(
                    stringResource(R.string.send_to_mac_pairing_footer, mac),
                    style = MaterialTheme.typography.bodySmall,
                )
                val status = when (val activity = state.activity) {
                    is SendToMacActivity.Pairing -> stringResource(R.string.send_to_mac_pairing, activity.macName) to false
                    is SendToMacActivity.PairingFailed -> sendToMacFailureText(activity.failure) to true
                    else -> null
                }
                status?.let { (text, failed) ->
                    Text(
                        text,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier
                            .testTag(AutomationIds.SEND_TO_MAC_PAIRING_STATUS)
                            .semantics { liveRegion = LiveRegionMode.Polite },
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = pair,
                enabled = canPair,
                modifier = Modifier.testTag(AutomationIds.SEND_TO_MAC_PAIRING_CONFIRM),
            ) {
                Text(stringResource(R.string.send_to_mac_pair))
            }
        },
        dismissButton = {
            TextButton(
                onClick = onClose,
                enabled = !pairing,
                modifier = Modifier.testTag(AutomationIds.SEND_TO_MAC_PAIRING_CANCEL),
            ) {
                Text(stringResource(R.string.action_cancel))
            }
        },
    )
}

/** What Send to Mac is doing, and whether it is a failure; null when there is nothing to show. */
@Composable
internal fun sendToMacActivityText(activity: SendToMacActivity): Pair<String, Boolean>? = when (activity) {
    SendToMacActivity.Idle -> null
    is SendToMacActivity.Pairing -> stringResource(R.string.send_to_mac_pairing, activity.macName) to false
    is SendToMacActivity.PairingFailed ->
        stringResource(R.string.send_to_mac_pairing_failed, sendToMacFailureText(activity.failure)) to true
    is SendToMacActivity.Sending -> stringResource(R.string.send_to_mac_sending, activity.macName) to false
    is SendToMacActivity.Sent -> stringResource(R.string.send_to_mac_sent, activity.macName) to false
    is SendToMacActivity.SendFailed ->
        stringResource(R.string.send_to_mac_send_failed, sendToMacFailureText(activity.failure)) to true
}

/** The reason in the user's language; a Mac's refusal is shown in the Mac's own words. */
@Composable
internal fun sendToMacFailureText(failure: SendToMacFailure): String = when (failure) {
    is SendToMacFailure.Rejected -> failure.reason
    is SendToMacFailure.Unreachable -> stringResource(R.string.send_to_mac_error_unreachable, failure.macName)
    SendToMacFailure.InvalidCode -> stringResource(R.string.send_to_mac_error_invalid_code)
    SendToMacFailure.MalformedHandshake -> stringResource(R.string.send_to_mac_error_malformed)
    SendToMacFailure.UnauthenticatedFrame -> stringResource(R.string.send_to_mac_error_unauthenticated)
    SendToMacFailure.UnexpectedResponse -> stringResource(R.string.send_to_mac_error_unexpected)
    SendToMacFailure.ReleaseTrainMismatch -> stringResource(R.string.send_to_mac_error_release_train)
    SendToMacFailure.MissingSessionToken -> stringResource(R.string.send_to_mac_error_missing_token)
    SendToMacFailure.NoCredentialIssued -> stringResource(R.string.send_to_mac_error_no_credential)
    SendToMacFailure.AcknowledgementTimedOut -> stringResource(R.string.send_to_mac_error_ack_timeout)
    SendToMacFailure.ConnectionLost -> stringResource(R.string.send_to_mac_error_connection_lost)
    SendToMacFailure.NotPaired -> stringResource(R.string.send_to_mac_error_not_paired)
    SendToMacFailure.NothingToSend -> stringResource(R.string.send_to_mac_error_nothing_to_send)
    SendToMacFailure.TranscriptTooLarge -> stringResource(R.string.send_to_mac_error_too_large)
}

private const val PAIRING_CODE_DIGITS = 6

// Room for a code typed with a space, such as "482 915".
private const val PAIRING_CODE_FIELD_LIMIT = 8
