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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.settings.ApiKeyStatusFilter

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

@Composable
internal fun KeyRow(
    provider: CloudProvider,
    saved: Boolean,
    failed: Boolean,
    actions: SettingsActions,
    modifier: Modifier = Modifier,
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
    }
}
