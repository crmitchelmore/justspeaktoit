package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CleanupModelPicker
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.OpenRouterBrowser
import com.justspeaktoit.android.cloud.OpenRouterBrowserFilter
import com.justspeaktoit.android.cloud.OpenRouterBrowserItem
import java.text.NumberFormat

/**
 * Native cleanup models first, then a separate **Browse OpenRouter models…** button that opens a
 * searchable OpenRouter browser with provider and price filters; each row opens a details page
 * where the model is chosen, matching the Mac and iPhone pickers.
 */
@Composable
fun CleanupModelPickerDialog(
    selected: CleanupModel,
    savedKeys: Set<CloudProvider>,
    onChoose: (CleanupModel) -> Unit,
    onDismiss: () -> Unit,
) {
    var browsing by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<OpenRouterBrowserItem?>(null) }
    var filter by remember { mutableStateOf(OpenRouterBrowserFilter()) }
    val direct = remember { CleanupModelPicker.direct() }
    val openRouterModels = remember { OpenRouterBrowser.cleanupItems }
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
        browsing -> OpenRouterBrowser.CLEANUP_TITLE
        else -> stringResource(R.string.cleanup_picker_title)
    }

    Dialog(onDismissRequest = back, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = back, modifier = Modifier.testTag(AutomationIds.CLEANUP_PICKER_BACK)) {
                        Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.action_back))
                    }
                    Text(
                        title,
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.semantics { heading() },
                    )
                }
                val shown = detail
                when {
                    shown != null -> OpenRouterModelDetail(
                        item = shown,
                        isSelected = shown.model == selected,
                        hasKey = CloudProvider.OpenRouter in savedKeys,
                        onChoose = { onChoose(shown.model) },
                    )
                    browsing -> OpenRouterModelList(
                        models = openRouterModels,
                        filter = filter,
                        selected = selected,
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
                                selected = selected.takeIf { it.isOpenRouter },
                                onOpen = { browsing = true },
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

/** The separate entry under the native models; shows the chosen OpenRouter model when there is one. */
@Composable
private fun BrowseOpenRouterRow(count: Int, selected: CleanupModel?, onOpen: () -> Unit) {
    val detail = selected?.let(CleanupModelPicker::selectionLabel)
        ?: pluralStringResource(R.plurals.cleanup_picker_openrouter_note, count, count)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.CLEANUP_PICKER_OPENROUTER)
            // Selected state lets screen readers say which choice is active when it is an OpenRouter model.
            .selectable(selected = selected != null, role = Role.Button, onClick = onOpen)
            .semantics { contentDescription = OpenRouterBrowser.BROWSE_TITLE + ", " + detail }
            .padding(vertical = 12.dp),
    ) {
        RadioButton(selected = selected != null, onClick = null)
        // The row's description already speaks this text; merging it too would read it twice.
        Column(modifier = Modifier.padding(start = 12.dp).weight(1f).clearAndSetSemantics {}) {
            Text(OpenRouterBrowser.BROWSE_TITLE, style = MaterialTheme.typography.bodyLarge)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text("›", style = MaterialTheme.typography.titleLarge, modifier = Modifier.clearAndSetSemantics {})
    }
}

@Composable
private fun OpenRouterModelList(
    models: List<OpenRouterBrowserItem>,
    filter: OpenRouterBrowserFilter,
    selected: CleanupModel,
    onFilter: (OpenRouterBrowserFilter) -> Unit,
    onOpen: (OpenRouterBrowserItem) -> Unit,
) {
    val providers = remember(models) { OpenRouterBrowser.providers(models) }
    val results = OpenRouterBrowser.filtered(models, filter)
    Column(modifier = Modifier.fillMaxSize()) {
        Text(
            OpenRouterBrowser.CLEANUP_INTRO,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(vertical = 4.dp),
        )
        OutlinedTextField(
            value = filter.query,
            onValueChange = { onFilter(filter.copy(query = it)) },
            label = { Text(OpenRouterBrowser.SEARCH_PLACEHOLDER) },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 8.dp)
                .testTag(AutomationIds.CLEANUP_PICKER_SEARCH),
        )
        ProviderChooser(providers, filter.provider) { onFilter(filter.copy(provider = it)) }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.CLEANUP_PICKER_ZERO_PRICES)
                .toggleable(
                    value = filter.freeOnly,
                    role = Role.Switch,
                    onValueChange = { onFilter(filter.copy(freeOnly = it)) },
                )
                .padding(vertical = 8.dp),
        ) {
            Text(OpenRouterBrowser.ZERO_PRICES, modifier = Modifier.weight(1f))
            Switch(checked = filter.freeOnly, onCheckedChange = null)
        }
        HorizontalDivider()
        LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth()) {
            items(results, key = { it.model.selectionId }) { model ->
                BrowserRow(model, model.model == selected) { onOpen(model) }
            }
            item {
                Text(
                    if (results.isEmpty()) stringResource(R.string.cleanup_picker_no_results)
                    else pluralStringResource(R.plurals.cleanup_picker_result_count, results.size, results.size),
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .padding(vertical = 12.dp)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
    }
}

@Composable
private fun ProviderChooser(providers: List<String>, chosen: String, onChoose: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val label = chosen.ifEmpty { OpenRouterBrowser.ALL_PROVIDERS }
    Box {
        OutlinedButton(
            onClick = { open = true },
            modifier = Modifier.testTag(AutomationIds.CLEANUP_PICKER_PROVIDER),
        ) {
            Text(stringResource(R.string.cleanup_picker_provider_choice, label))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(OpenRouterBrowser.ALL_PROVIDERS) },
                onClick = {
                    onChoose("")
                    open = false
                },
                modifier = Modifier.testTag(AutomationIds.CLEANUP_PICKER_ALL_PROVIDERS),
            )
            providers.forEach { provider ->
                DropdownMenuItem(
                    text = { Text(provider) },
                    onClick = {
                        onChoose(provider)
                        open = false
                    },
                    modifier = Modifier.testTag(AutomationIds.cleanupPickerProvider(provider)),
                )
            }
        }
    }
}

@Composable
private fun BrowserRow(item: OpenRouterBrowserItem, isSelected: Boolean, onOpen: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.cleanupPickerModel(item.model.selectionId))
            // Opens the details page; selected state says which model is in use.
            .selectable(selected = isSelected, role = Role.Button, onClick = onOpen)
            .padding(vertical = 8.dp),
    ) {
        RadioButton(selected = isSelected, onClick = null)
        Column(modifier = Modifier.padding(start = 12.dp).weight(1f)) {
            Text(item.name, style = MaterialTheme.typography.bodyLarge)
            Text(
                item.subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text("›", style = MaterialTheme.typography.titleLarge, modifier = Modifier.clearAndSetSemantics {})
    }
}

@Composable
private fun OpenRouterModelDetail(
    item: OpenRouterBrowserItem,
    isSelected: Boolean,
    hasKey: Boolean,
    onChoose: () -> Unit,
) {
    val uriHandler = LocalUriHandler.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(vertical = 8.dp),
    ) {
        Text(
            item.slug,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (item.summary.isNotEmpty()) {
            Text(item.summary, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 8.dp))
        }
        DetailLine(stringResource(R.string.cleanup_picker_detail_provider), item.provider)
        item.contextLength?.let { length ->
            val tokens = NumberFormat.getIntegerInstance().format(length)
            DetailLine(
                stringResource(R.string.cleanup_picker_detail_context),
                stringResource(R.string.cleanup_picker_detail_tokens, tokens),
            )
        }
        if (item.speed.isNotEmpty()) DetailLine(stringResource(R.string.cleanup_picker_detail_speed), item.speed)
        if (item.strengths.isNotEmpty()) {
            DetailLine(stringResource(R.string.cleanup_picker_detail_strengths), item.strengths.joinToString(", "))
        }
        Text(
            stringResource(R.string.cleanup_picker_detail_pricing_heading),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(top = 16.dp).semantics { heading() },
        )
        val pricing = item.pricing
        if (pricing != null) {
            DetailLine(
                stringResource(R.string.cleanup_picker_detail_pricing),
                stringResource(R.string.cleanup_picker_detail_tokens, pricing),
            )
            Text(
                OpenRouterBrowser.PRICING_CAVEAT,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Text(OpenRouterBrowser.PRICING_UNLISTED, style = MaterialTheme.typography.bodyMedium)
        }
        item.modelPageUrl?.let { url ->
            TextButton(
                onClick = { uriHandler.openUri(url) },
                modifier = Modifier.testTag(AutomationIds.CLEANUP_PICKER_MODEL_PAGE),
            ) {
                Text(stringResource(R.string.cleanup_picker_detail_link))
            }
        }
        Button(
            onClick = onChoose,
            enabled = !isSelected,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 16.dp)
                .testTag(AutomationIds.CLEANUP_PICKER_USE),
        ) {
            Text(if (isSelected) OpenRouterBrowser.CLEANUP_SELECTED else OpenRouterBrowser.CLEANUP_USE)
        }
        Text(
            OpenRouterBrowser.CLEANUP_ROUTE_NOTE,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp),
        )
        if (!hasKey) {
            Text(
                stringResource(R.string.settings_cleanup_needs_key, CloudProvider.OpenRouter.displayName),
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
    }
}
