package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.settings.SettingsSearchEntry
import com.justspeaktoit.android.settings.SettingsSearchIndex
import com.justspeaktoit.android.settings.SettingsSearchRecents
import com.justspeaktoit.android.settings.SettingsSearchResult

class SettingsActions(
    val onBack: () -> Unit,
    val onSaveKey: (CloudProvider, String) -> Unit,
    val onRemoveKey: (CloudProvider) -> Unit,
    val onChooseModel: (CloudModel) -> Unit,
    val onCleanupChanged: (Boolean) -> Unit,
)

/** Where a search result scrolls to on this screen. */
private fun anchorFor(entry: SettingsSearchEntry): String = when {
    entry.id.startsWith(SettingsSearchIndex.MODEL_PREFIX) -> "android.cloudModel"
    else -> entry.id
}

@Composable
fun SettingsScreen(state: DictationUiState, actions: SettingsActions) {
    val context = LocalContext.current
    val searchIndex = remember {
        context.assets.open("settings_search.json").bufferedReader().use {
            SettingsSearchIndex.fromCatalogueJson(it.readText())
        }
    }
    val scrollState = rememberScrollState()
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    var query by rememberSaveable { mutableStateOf("") }
    var recents by remember { mutableStateOf(emptyList<String>()) }
    var highlighted by remember { mutableStateOf<String?>(null) }
    val anchors = remember { mutableStateMapOf<String, Int>() }
    val highlightColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.16f)
    LaunchedEffect(highlighted) {
        if (highlighted != null) {
            delay(2_500)
            highlighted = null
        }
    }
    // Records where each search destination sits and tints it briefly when a result opens it.
    fun anchor(id: String): Modifier = Modifier
        .onGloballyPositioned { anchors[id] = it.positionInParent().y.toInt() }
        .background(if (highlighted == id) highlightColor else Color.Transparent, RoundedCornerShape(8.dp))
    fun open(entry: SettingsSearchEntry) {
        recents = SettingsSearchRecents.recording(entry.id, recents)
        query = ""
        focusManager.clearFocus()
        val target = anchorFor(entry)
        highlighted = target
        scope.launch { anchors[target]?.let { scrollState.animateScrollTo(it) } }
    }

    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(scrollState)
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = actions.onBack) {
                    Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.action_back))
                }
                Text(
                    stringResource(R.string.settings_title),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            SettingsSearchField(query, onQueryChange = { query = it })
            if (query.isNotBlank()) {
                SettingsSearchResults(
                    // Only destinations this screen renders; the catalogue can run ahead of the UI.
                    results = searchIndex.search(query, limit = 20).filter { anchorFor(it.entry) in anchors },
                    completions = searchIndex.completions(query),
                    onComplete = { query = it },
                    onOpen = ::open,
                )
                return@Column
            }
            val recentEntries = recents.mapNotNull(searchIndex::entry).filter { anchorFor(it) in anchors }
            if (recentEntries.isNotEmpty()) {
                Text(
                    stringResource(R.string.settings_search_recent),
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.semantics { heading() },
                )
                recentEntries.forEach { entry -> SearchResultRow(SettingsSearchResult(entry, 0, null), ::open) }
                HorizontalDivider()
            }

            SectionTitle(R.string.settings_cloud_model_title, anchor("android.cloudModel"))
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
                modifier = anchor("android.cleanup")
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
            if (state.cleanupEnabled && CloudProvider.OpenRouter !in state.savedKeys) {
                Text(stringResource(R.string.settings_cleanup_needs_key), color = MaterialTheme.colorScheme.error)
            }

            HorizontalDivider()
            SectionTitle(R.string.settings_keys_title, anchor("android.apiKeys"))
            Text(stringResource(R.string.settings_keys_note), style = MaterialTheme.typography.bodyMedium)
            if (state.keyStoreError) {
                Text(stringResource(R.string.settings_key_error), color = MaterialTheme.colorScheme.error)
            }
            CloudCatalog.providers.forEach { provider ->
                KeyRow(
                    provider,
                    saved = provider in state.savedKeys,
                    actions,
                    anchor("${SettingsSearchIndex.KEY_PREFIX}${provider.id}"),
                )
            }
        }
    }
}

@Composable
private fun SectionTitle(@StringRes title: Int, modifier: Modifier = Modifier) {
    Text(
        stringResource(title),
        style = MaterialTheme.typography.titleMedium,
        modifier = modifier.semantics { heading() },
    )
}

@Composable
private fun SettingsSearchField(query: String, onQueryChange: (String) -> Unit) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        label = { Text(stringResource(R.string.settings_search_hint)) },
        leadingIcon = { Icon(painterResource(R.drawable.ic_search), contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(painterResource(R.drawable.ic_close), stringResource(R.string.settings_search_clear))
                }
            }
        },
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("settingsSearchField"),
    )
}

@Composable
private fun SettingsSearchResults(
    results: List<SettingsSearchResult>,
    completions: List<String>,
    onComplete: (String) -> Unit,
    onOpen: (SettingsSearchEntry) -> Unit,
) {
    if (completions.isNotEmpty()) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(completions) { completion ->
                SuggestionChip(
                    onClick = { onComplete(completion) },
                    label = { Text(completion) },
                    modifier = Modifier.testTag("settingsSearchCompletion.$completion"),
                )
            }
        }
    }
    val summary = if (results.isEmpty()) {
        stringResource(R.string.settings_search_no_results)
    } else {
        pluralStringResource(R.plurals.settings_search_count, results.size, results.size)
    }
    Text(
        summary,
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
    results.forEach { result -> SearchResultRow(result, onOpen) }
}

@Composable
private fun SearchResultRow(result: SettingsSearchResult, onOpen: (SettingsSearchEntry) -> Unit) {
    val entry = result.entry
    val detail = result.matchedKeyword?.let { stringResource(R.string.settings_search_matches, it, entry.summary) }
        ?: entry.summary
    val description = stringResource(R.string.settings_search_result_description, entry.title, entry.sectionTitle)
    Column(
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = { onOpen(entry) })
            .padding(vertical = 8.dp)
            .testTag(entry.resultTag)
            .semantics(mergeDescendants = true) { contentDescription = "$description. $detail" },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(entry.title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            Text(entry.sectionTitle, style = MaterialTheme.typography.labelMedium)
        }
        Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun KeyRow(provider: CloudProvider, saved: Boolean, actions: SettingsActions, modifier: Modifier = Modifier) {
    // The entered key is held only in this composable until saved; saved keys are never read back.
    var draft by remember(provider, saved) { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = modifier) {
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
