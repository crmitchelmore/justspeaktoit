package com.justspeaktoit.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CleanupModelPicker
import com.justspeaktoit.android.cloud.CloudProvider

/**
 * Native cleanup models first, then one OpenRouter row that opens a searchable OpenRouter list,
 * matching the Mac and iPhone pickers.
 */
@Composable
fun CleanupModelPickerDialog(
    selected: CleanupModel,
    savedKeys: Set<CloudProvider>,
    onChoose: (CleanupModel) -> Unit,
    onDismiss: () -> Unit,
) {
    var browsingOpenRouter by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    val direct = remember { CleanupModelPicker.direct() }
    val openRouter = remember { CleanupModelPicker.openRouter() }
    val back: () -> Unit = {
        if (browsingOpenRouter) {
            browsingOpenRouter = false
            query = ""
        } else {
            onDismiss()
        }
    }

    Dialog(onDismissRequest = back, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = back, modifier = Modifier.testTag(AutomationIds.CLEANUP_PICKER_BACK)) {
                        Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.action_back))
                    }
                    Text(
                        if (browsingOpenRouter) CloudProvider.OpenRouter.displayName
                        else stringResource(R.string.cleanup_picker_title),
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                if (browsingOpenRouter) {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        label = { Text(stringResource(R.string.cleanup_picker_search)) },
                        singleLine = true,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 8.dp)
                            .testTag(AutomationIds.CLEANUP_PICKER_SEARCH),
                    )
                    val results = CleanupModelPicker.filter(openRouter, query)
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        items(results, key = { it.selectionId }) { model ->
                            ModelRow(model, model == selected, model.provider in savedKeys) { onChoose(model) }
                        }
                        item {
                            Text(
                                stringResource(
                                    if (results.isEmpty()) R.string.cleanup_picker_no_results
                                    else R.string.cleanup_picker_openrouter_footer,
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.padding(vertical = 12.dp),
                            )
                        }
                    }
                } else {
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        items(direct, key = { it.selectionId }) { model ->
                            ModelRow(model, model == selected, model.provider in savedKeys) { onChoose(model) }
                        }
                        item {
                            HorizontalDivider()
                            OpenRouterRow(
                                count = openRouter.size,
                                selected = selected.takeIf { it.isOpenRouter },
                                onOpen = { browsingOpenRouter = true },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ModelRow(model: CleanupModel, isSelected: Boolean, hasKey: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.cleanupPickerModel(model.selectionId))
            .selectable(selected = isSelected, role = Role.RadioButton, onClick = onClick)
            .padding(vertical = 8.dp),
    ) {
        RadioButton(selected = isSelected, onClick = null)
        Column(modifier = Modifier.padding(start = 12.dp).weight(1f)) {
            Text(model.displayName, style = MaterialTheme.typography.bodyLarge)
            Text(
                if (hasKey) model.vendor
                else model.vendor + " · " + stringResource(R.string.settings_key_not_set),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun OpenRouterRow(count: Int, selected: CleanupModel?, onOpen: () -> Unit) {
    val detail = selected?.displayName ?: pluralStringResource(R.plurals.cleanup_picker_openrouter_note, count, count)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.CLEANUP_PICKER_OPENROUTER)
            .clickable(role = Role.Button, onClick = onOpen)
            .semantics(mergeDescendants = true) {
                contentDescription = CloudProvider.OpenRouter.displayName + ", " + detail
            }
            .padding(vertical = 12.dp),
    ) {
        RadioButton(selected = selected != null, onClick = null)
        Column(modifier = Modifier.padding(start = 12.dp).weight(1f)) {
            Text(CloudProvider.OpenRouter.displayName, style = MaterialTheme.typography.bodyLarge)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text("›", style = MaterialTheme.typography.titleLarge)
    }
}
