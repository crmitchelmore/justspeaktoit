package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.BalanceAccount
import com.justspeaktoit.android.cloud.BalanceEntry
import com.justspeaktoit.android.cloud.BalanceFormatter
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.settings.ApiKeyStatusFilter
import java.text.DateFormat
import java.util.Date

@Composable
internal fun KeyFilterPicker(filter: ApiKeyStatusFilter, onFilter: (ApiKeyStatusFilter) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.settings_keys_filter), style = MaterialTheme.typography.labelLarge)
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth().testTag(AutomationIds.API_KEYS_FILTER)) {
            ApiKeyStatusFilter.entries.forEachIndexed { index, option ->
                SegmentedButton(
                    selected = option == filter,
                    onClick = { onFilter(option) },
                    shape = SegmentedButtonDefaults.itemShape(index, ApiKeyStatusFilter.entries.size),
                ) {
                    Text(stringResource(option.label))
                }
            }
        }
    }
}

/** What a key card knows about its account's balance; null when the account has no balance entry. */
internal data class KeyBalance(val account: BalanceAccount, val checkable: Boolean, val entry: BalanceEntry?)

@Composable
internal fun KeyRow(
    provider: CloudProvider,
    saved: Boolean,
    failed: Boolean,
    actions: SettingsActions,
    modifier: Modifier = Modifier,
    balance: KeyBalance? = null,
) {
    // The entered key is held only in this composable until saved; saved keys are never read back.
    var draft by remember(provider, saved) { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(provider.displayName, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            Text(
                stringResource(
                    when {
                        failed -> R.string.settings_key_failed
                        saved -> R.string.settings_key_saved
                        else -> R.string.settings_key_not_set
                    },
                ),
                color = when {
                    failed -> MaterialTheme.colorScheme.error
                    saved -> MaterialTheme.colorScheme.primary
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                },
                style = MaterialTheme.typography.labelLarge,
            )
        }
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            label = { Text(stringResource(R.string.settings_key_label, provider.displayName)) },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = {
                    actions.onSaveKey(provider, draft)
                    draft = ""
                },
                enabled = draft.isNotBlank()) {
                Text(stringResource(R.string.action_save))
            }
            if (saved) {
                TextButton(onClick = { actions.onRemoveKey(provider) }) { Text(stringResource(R.string.action_remove)) }
            }
        }
        if (balance != null) BalanceLine(provider, saved, balance, actions)
    }
}

/**
 * The account balance under a key, as on macOS, iOS, Windows and Linux. It never holds or shows the
 * key, and checking never blocks the key field: the request runs in the ViewModel's store.
 */
@Composable
private fun BalanceLine(provider: CloudProvider, saved: Boolean, balance: KeyBalance, actions: SettingsActions) {
    val credentialId = provider.credentialId
    val text = when {
        !balance.checkable -> stringResource(R.string.settings_key_balance_not_shown, balance.account.reason.orEmpty())
        !saved -> stringResource(R.string.settings_key_balance_needs_key, balance.account.displayName)
        else -> when (val entry = balance.entry) {
            null -> stringResource(R.string.settings_key_balance_idle)
            BalanceEntry.Checking -> stringResource(R.string.settings_key_balance_checking)
            is BalanceEntry.Loaded -> stringResource(
                R.string.settings_key_balance_checked,
                BalanceFormatter.line(entry.state),
                DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(entry.checkedAtMillis)),
            )
        }
    }
    Text(
        text.trim(),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        // Polite, so a finished check is read out without interrupting typing.
        modifier = Modifier
            .testTag(AutomationIds.apiKeyBalance(credentialId))
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
    val billingUrl = balance.account.billingUrl
    val canCheck = balance.checkable && saved
    if (!canCheck && billingUrl == null) return
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (canCheck) {
            val description = stringResource(R.string.action_check_balance_description, provider.displayName)
            TextButton(
                onClick = { actions.onCheckBalance(provider) },
                enabled = balance.entry != BalanceEntry.Checking,
                modifier = Modifier
                    .testTag(AutomationIds.apiKeyBalanceCheck(credentialId))
                    .semantics { contentDescription = description },
            ) {
                Text(stringResource(R.string.action_check_balance))
            }
        }
        if (billingUrl != null) {
            val uriHandler = LocalUriHandler.current
            val description = stringResource(R.string.action_open_billing_description, balance.account.displayName)
            TextButton(
                onClick = { uriHandler.openUri(billingUrl) },
                modifier = Modifier
                    .testTag(AutomationIds.apiKeyBilling(credentialId))
                    .semantics { contentDescription = description },
            ) {
                Text(stringResource(R.string.action_open_billing))
            }
        }
    }
}
