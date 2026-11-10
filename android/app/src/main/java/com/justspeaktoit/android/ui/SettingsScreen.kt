package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CleanupModelPicker
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.dictation.DictationUiState

class SettingsActions(
    val onBack: () -> Unit,
    val onSaveKey: (CloudProvider, String) -> Unit,
    val onRemoveKey: (CloudProvider) -> Unit,
    val onChooseModel: (CloudModel) -> Unit,
    val onCleanupChanged: (Boolean) -> Unit,
    val onKeepAudioOnCancelChanged: (Boolean) -> Unit,
    val onChooseCleanupModel: (CleanupModel) -> Unit,
)

@Composable
fun SettingsScreen(state: DictationUiState, actions: SettingsActions) {
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = actions.onBack, modifier = Modifier.testTag(AutomationIds.SETTINGS_BACK)) {
                    Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.action_back))
                }
                Text(
                    stringResource(R.string.settings_title),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            SectionTitle(R.string.settings_cloud_model_title)
            CloudCatalog.transcriptionModels.forEach { model ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .selectable(
                            selected = model == state.cloudModel,
                            role = Role.RadioButton,
                            onClick = { actions.onChooseModel(model) },
                        ),
                ) {
                    RadioButton(selected = model == state.cloudModel, onClick = null)
                    Text(model.displayName, modifier = Modifier.padding(start = 8.dp))
                }
            }

            HorizontalDivider()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .toggleable(
                        value = state.cleanupEnabled,
                        role = Role.Switch,
                        onValueChange = actions.onCleanupChanged,
                    ),
            ) {
                Text(
                    stringResource(R.string.settings_cleanup_title),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = state.cleanupEnabled, onCheckedChange = null)
            }
            Text(stringResource(R.string.settings_cleanup_note), style = MaterialTheme.typography.bodyMedium)
            CleanupModelRow(state, actions)
            if (state.cleanupEnabled && state.cleanupModel.provider !in state.savedKeys) {
                Text(
                    stringResource(R.string.settings_cleanup_needs_key, state.cleanupModel.provider.displayName),
                    color = MaterialTheme.colorScheme.error,
                )
            }

            HorizontalDivider()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .toggleable(
                        value = state.keepAudioOnCancel,
                        role = Role.Switch,
                        onValueChange = actions.onKeepAudioOnCancelChanged,
                    ),
            ) {
                Text(
                    stringResource(R.string.settings_keep_audio_title),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = state.keepAudioOnCancel, onCheckedChange = null)
            }
            Text(stringResource(R.string.settings_keep_audio_note), style = MaterialTheme.typography.bodyMedium)

            HorizontalDivider()
            SectionTitle(R.string.settings_keys_title)
            Text(stringResource(R.string.settings_keys_note), style = MaterialTheme.typography.bodyMedium)
            if (state.keyStoreError) {
                Text(stringResource(R.string.settings_key_error), color = MaterialTheme.colorScheme.error)
            }
            CloudCatalog.providers.forEach { provider ->
                KeyRow(provider, saved = provider in state.savedKeys, actions)
            }
        }
    }
}

@Composable
private fun CleanupModelRow(state: DictationUiState, actions: SettingsActions) {
    var picking by remember { mutableStateOf(false) }
    val title = stringResource(R.string.settings_cleanup_model)
    val label = CleanupModelPicker.selectionLabel(state.cleanupModel)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button) { picking = true }
            .semantics(mergeDescendants = true) { contentDescription = "$title, $label" }
            .padding(vertical = 8.dp),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.weight(1f),
        )
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.primary,
        )
    }
    if (picking) {
        CleanupModelPickerDialog(
            selected = state.cleanupModel,
            savedKeys = state.savedKeys,
            onChoose = {
                actions.onChooseCleanupModel(it)
                picking = false
            },
            onDismiss = { picking = false },
        )
    }
}

@Composable
private fun SectionTitle(@StringRes title: Int) {
    Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
}

@Composable
private fun KeyRow(provider: CloudProvider, saved: Boolean, actions: SettingsActions) {
    // The entered key is held only in this composable until saved; saved keys are never read back.
    var draft by remember(provider, saved) { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(provider.displayName, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            Text(
                stringResource(if (saved) R.string.settings_key_saved else R.string.settings_key_not_set),
                color = if (saved) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
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
