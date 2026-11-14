package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CleanupModelPicker
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.OpenRouterBrowser
import com.justspeaktoit.android.cloud.OpenRouterBrowserFilter
import com.justspeaktoit.android.cloud.OpenRouterBrowserItem

/**
 * Native cleanup models first, then a separate **Browse OpenRouter models…** button that opens a
 * searchable OpenRouter browser with provider and price filters; each row opens a details page
 * where the model is chosen, matching the Mac and iPhone pickers. With live discovery on, the browser
 * also lists OpenAI models OpenRouter offers today.
 */
@Composable
fun CleanupModelPickerDialog(
    selected: CleanupModel,
    savedKeys: Set<CloudProvider>,
    onChoose: (CleanupModel) -> Unit,
    onDismiss: () -> Unit,
    discovery: OpenRouterDiscoveryUi = OpenRouterDiscoveryUi(),
) {
    var browsing by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<OpenRouterBrowserItem?>(null) }
    var filter by remember { mutableStateOf(OpenRouterBrowserFilter()) }
    val direct = remember { CleanupModelPicker.direct() }
    val found = discovery.state.cleanupModels
    val openRouterModels = remember(found, discovery.cleanupEnabled, selected.selectionId) {
        OpenRouterBrowser.cleanupItems(found, discovery.cleanupEnabled, selected.selectionId)
    }
    val copy = OpenRouterBrowserCopy.Cleanup
    // Opening the browser refreshes discovery when it is on and its cache is stale.
    LaunchedEffect(browsing) { if (browsing) discovery.onRefreshCleanup(false) }
    val back: () -> Unit = {
        when {
            detail != null -> detail = null
            browsing -> {
                browsing = false
                filter = OpenRouterBrowserFilter()
            }
            else -> onDismiss()
        }
    }
    val title = when {
        detail != null -> detail?.name.orEmpty()
        browsing -> copy.title
        else -> stringResource(R.string.cleanup_picker_title)
    }
    val choose: (OpenRouterBrowserItem) -> Unit = { item ->
        CloudCatalog.findCleanupModel(item.selectionId)?.let(onChoose)
    }

    ModelPickerScaffold(title, copy.ids, back) {
        val shown = detail
        when {
            shown != null -> OpenRouterModelDetail(
                copy = copy,
                item = shown,
                isSelected = shown.selectionId == selected.selectionId,
                hasKey = CloudProvider.OpenRouter in savedKeys,
                needsKey = needsKeyText(CloudProvider.OpenRouter, cleanup = true),
                onChoose = { choose(shown) },
            )
            browsing -> OpenRouterModelList(
                copy = copy,
                models = openRouterModels,
                filter = filter,
                isSelected = { it.selectionId == selected.selectionId },
                discovery = OpenRouterDiscoveryControls(
                    loading = discovery.state.cleanupLoading,
                    failed = discovery.state.cleanupFailed,
                    onRefresh = { discovery.onRefreshCleanup(true) },
                    enabled = discovery.cleanupEnabled,
                    onEnabledChanged = discovery.onCleanupEnabledChanged,
                ),
                onFilter = { filter = it },
                onOpen = { detail = it },
            )
            else -> LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(direct, key = { it.selectionId }) { model ->
                    ModelRow(model, model == selected, model.provider in savedKeys) { onChoose(model) }
                }
                item {
                    HorizontalDivider()
                    BrowseOpenRouterRow(
                        count = openRouterModels.size,
                        selectedLabel = selected.takeIf { it.isOpenRouter }?.let(CleanupModelPicker::selectionLabel),
                        onOpen = { browsing = true },
                        modifier = Modifier.testTag(copy.ids.openRouter),
                    )
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
            .testTag(AutomationIds.CLEANUP_PICKER.model(model.selectionId))
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
