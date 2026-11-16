package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.OpenRouterBrowser
import com.justspeaktoit.android.cloud.OpenRouterBrowserFilter
import com.justspeaktoit.android.cloud.OpenRouterBrowserItem
import com.justspeaktoit.android.cloud.OpenRouterDiscovery
import com.justspeaktoit.android.cloud.OpenRouterDiscoveryState
import java.text.NumberFormat

/** What one picker's OpenRouter browser says, and the IDs its controls carry. */
internal class OpenRouterBrowserCopy(
    val title: String,
    val intro: String,
    val use: String,
    val selected: String,
    val routeNote: String,
    val ids: ModelPickerIds,
) {
    companion object {
        val Cleanup = OpenRouterBrowserCopy(
            title = OpenRouterBrowser.CLEANUP_TITLE,
            intro = OpenRouterBrowser.CLEANUP_INTRO,
            use = OpenRouterBrowser.CLEANUP_USE,
            selected = OpenRouterBrowser.CLEANUP_SELECTED,
            routeNote = OpenRouterBrowser.CLEANUP_ROUTE_NOTE,
            ids = AutomationIds.CLEANUP_PICKER,
        )
        val Transcription = OpenRouterBrowserCopy(
            title = OpenRouterBrowser.TRANSCRIPTION_TITLE,
            intro = OpenRouterBrowser.TRANSCRIPTION_INTRO,
            use = OpenRouterBrowser.TRANSCRIPTION_USE,
            selected = OpenRouterBrowser.TRANSCRIPTION_SELECTED,
            routeNote = OpenRouterBrowser.TRANSCRIPTION_ROUTE_NOTE,
            ids = AutomationIds.TRANSCRIPTION_PICKER,
        )
    }
}

/**
 * Live discovery in a browser: its status and Refresh, and for cleanup the opt-in switch ([enabled] is
 * null where there is no switch).
 */
class OpenRouterDiscoveryControls(
    val loading: Boolean = false,
    val failed: Boolean = false,
    val onRefresh: (() -> Unit)? = null,
    val enabled: Boolean? = null,
    val onEnabledChanged: (Boolean) -> Unit = {},
)

/** Discovery's state and actions, handed from Settings to every picker that browses OpenRouter. */
class OpenRouterDiscoveryUi(
    val state: OpenRouterDiscoveryState = OpenRouterDiscoveryState(),
    val cleanupEnabled: Boolean = false,
    val onCleanupEnabledChanged: (Boolean) -> Unit = {},
    val onRefreshCleanup: (Boolean) -> Unit = {},
    val onRefreshTranscription: (Boolean) -> Unit = {},
)

/** A full-screen picker with a back button and heading. */
@Composable
internal fun ModelPickerScaffold(
    title: String,
    ids: ModelPickerIds,
    onBack: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(onDismissRequest = onBack, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onBack, modifier = Modifier.testTag(ids.back)) {
                        Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.action_back))
                    }
                    Text(
                        title,
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.semantics { heading() },
                    )
                }
                content()
            }
        }
    }
}

/**
 * The separate **Browse OpenRouter models…** entry under the native models; shows the chosen
 * OpenRouter model as "OpenRouter › name" when there is one. [modifier] carries its test tag.
 */
@Composable
internal fun BrowseOpenRouterRow(
    count: Int,
    selectedLabel: String?,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
    warning: String? = null,
) {
    val detail = selectedLabel ?: pluralStringResource(R.plurals.cleanup_picker_openrouter_note, count, count)
    val spoken = listOfNotNull(OpenRouterBrowser.BROWSE_TITLE, detail, warning).joinToString(", ")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            // Selected state lets screen readers say which choice is active when it is an OpenRouter model.
            .selectable(selected = selectedLabel != null, role = Role.Button, onClick = onOpen)
            .semantics { contentDescription = spoken }
            .padding(vertical = 12.dp),
    ) {
        RadioButton(selected = selectedLabel != null, onClick = null)
        // The row's description already speaks this text; merging it too would read it twice.
        Column(modifier = Modifier.padding(start = 12.dp).weight(1f).clearAndSetSemantics {}) {
            Text(OpenRouterBrowser.BROWSE_TITLE, style = MaterialTheme.typography.bodyLarge)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            warning?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
        }
        Text("›", style = MaterialTheme.typography.titleLarge, modifier = Modifier.clearAndSetSemantics {})
    }
}

/** Search, provider and price filters over the browser's models; each row opens its details page. */
@Composable
internal fun OpenRouterModelList(
    copy: OpenRouterBrowserCopy,
    models: List<OpenRouterBrowserItem>,
    filter: OpenRouterBrowserFilter,
    isSelected: (OpenRouterBrowserItem) -> Boolean,
    discovery: OpenRouterDiscoveryControls,
    onFilter: (OpenRouterBrowserFilter) -> Unit,
    onOpen: (OpenRouterBrowserItem) -> Unit,
) {
    val ids = copy.ids
    val providers = remember(models) { OpenRouterBrowser.providers(models) }
    val results = OpenRouterBrowser.filtered(models, filter)
    Column(modifier = Modifier.fillMaxSize()) {
        Text(copy.intro, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 4.dp))
        DiscoverySection(ids, discovery)
        OutlinedTextField(
            value = filter.query,
            onValueChange = { onFilter(filter.copy(query = it)) },
            label = { Text(OpenRouterBrowser.SEARCH_PLACEHOLDER) },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 8.dp)
                .testTag(ids.search),
        )
        ProviderChooser(ids, providers, filter.provider) { onFilter(filter.copy(provider = it)) }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(ids.zeroPrices)
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
            items(results, key = { it.selectionId }) { item ->
                BrowserRow(ids, item, isSelected(item)) { onOpen(item) }
            }
            item {
                Text(
                    if (results.isEmpty()) OpenRouterBrowser.EMPTY_RESULTS
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
private fun DiscoverySection(ids: ModelPickerIds, discovery: OpenRouterDiscoveryControls) {
    discovery.enabled?.let { enabled ->
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(ids.discovery)
                .toggleable(value = enabled, role = Role.Switch, onValueChange = discovery.onEnabledChanged)
                .padding(vertical = 8.dp),
        ) {
            Text(OpenRouterBrowser.DISCOVERY_SETTING_TITLE, modifier = Modifier.weight(1f))
            Switch(checked = enabled, onCheckedChange = null)
        }
        Text(
            OpenRouterBrowser.DISCOVERY_NOTE,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    val refresh = discovery.onRefresh?.takeIf { discovery.enabled != false } ?: return
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        val status = when {
            discovery.loading -> stringResource(R.string.openrouter_discovery_loading)
            discovery.failed -> OpenRouterDiscovery.FAILURE
            else -> ""
        }
        Text(
            status,
            style = MaterialTheme.typography.bodySmall,
            color = if (discovery.failed && !discovery.loading) {
                MaterialTheme.colorScheme.error
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            modifier = Modifier
                .weight(1f)
                .testTag(ids.status)
                .semantics { liveRegion = LiveRegionMode.Polite },
        )
        TextButton(
            onClick = refresh,
            enabled = !discovery.loading,
            modifier = Modifier.testTag(ids.refresh),
        ) {
            Text(stringResource(R.string.openrouter_discovery_refresh))
        }
    }
}

@Composable
private fun ProviderChooser(ids: ModelPickerIds, providers: List<String>, chosen: String, onChoose: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val label = chosen.ifEmpty { OpenRouterBrowser.ALL_PROVIDERS }
    Box {
        OutlinedButton(onClick = { open = true }, modifier = Modifier.testTag(ids.provider)) {
            Text(stringResource(R.string.cleanup_picker_provider_choice, label))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(OpenRouterBrowser.ALL_PROVIDERS) },
                onClick = {
                    onChoose("")
                    open = false
                },
                modifier = Modifier.testTag(ids.allProviders),
            )
            providers.forEach { provider ->
                DropdownMenuItem(
                    text = { Text(provider) },
                    onClick = {
                        onChoose(provider)
                        open = false
                    },
                    modifier = Modifier.testTag(ids.provider(provider)),
                )
            }
        }
    }
}

@Composable
private fun BrowserRow(ids: ModelPickerIds, item: OpenRouterBrowserItem, isSelected: Boolean, onOpen: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(ids.model(item.selectionId))
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

/** A model's details and the button that chooses it. */
@Composable
internal fun OpenRouterModelDetail(
    copy: OpenRouterBrowserCopy,
    item: OpenRouterBrowserItem,
    isSelected: Boolean,
    hasKey: Boolean,
    needsKey: String,
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
        if (item.unqualified) {
            Text(
                OpenRouterBrowser.UNQUALIFIED_WARNING,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
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
        when {
            pricing != null -> {
                DetailLine(
                    stringResource(R.string.cleanup_picker_detail_pricing),
                    stringResource(R.string.cleanup_picker_detail_tokens, pricing),
                )
                Note(OpenRouterBrowser.PRICING_CAVEAT)
            }
            item.listedPrices.isNotEmpty() -> {
                item.listedPrices.toSortedMap().forEach { (key, value) -> DetailLine(key, value) }
                Note(OpenRouterBrowser.LISTED_PRICES_NOTE)
            }
            else -> Text(OpenRouterBrowser.PRICING_UNLISTED, style = MaterialTheme.typography.bodyMedium)
        }
        item.modelPageUrl?.let { url ->
            TextButton(onClick = { uriHandler.openUri(url) }, modifier = Modifier.testTag(copy.ids.modelPage)) {
                Text(stringResource(R.string.cleanup_picker_detail_link))
            }
        }
        Button(
            onClick = onChoose,
            enabled = !isSelected,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 16.dp)
                .testTag(copy.ids.use),
        ) {
            Text(if (isSelected) copy.selected else copy.use)
        }
        Note(copy.routeNote, Modifier.padding(top = 4.dp))
        if (!hasKey) {
            Text(needsKey, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 4.dp))
        }
    }
}

@Composable
private fun Note(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier,
    )
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
    }
}

/** The key note under a picker's model when its provider has no saved key. */
@Composable
internal fun needsKeyText(provider: CloudProvider, cleanup: Boolean): String =
    if (cleanup) {
        stringResource(R.string.settings_cleanup_needs_key, provider.displayName)
    } else {
        stringResource(R.string.transcription_picker_needs_key, provider.displayName)
    }
