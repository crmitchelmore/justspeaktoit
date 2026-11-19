package com.justspeaktoit.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.settings.SettingsSearchEntry
import com.justspeaktoit.android.settings.SettingsSearchResult

@Composable
internal fun SettingsSearchField(query: String, onQueryChange: (String) -> Unit) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        label = { Text(stringResource(R.string.settings_search_hint)) },
        leadingIcon = {
            // Decorative: the field's label already says "Search settings".
            Icon(painterResource(R.drawable.ic_search), contentDescription = null)
        },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(
                    onClick = { onQueryChange("") },
                    modifier = Modifier.testTag(AutomationIds.SETTINGS_SEARCH_CLEAR),
                ) {
                    Icon(painterResource(R.drawable.ic_close), stringResource(R.string.settings_search_clear))
                }
            }
        },
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.SETTINGS_SEARCH),
    )
}

@Composable
internal fun SettingsSearchResults(
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
internal fun SearchResultRow(result: SettingsSearchResult, onOpen: (SettingsSearchEntry) -> Unit) {
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
