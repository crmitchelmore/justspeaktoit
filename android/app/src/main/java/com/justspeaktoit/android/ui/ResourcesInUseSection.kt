package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.justspeaktoit.android.R
import com.justspeaktoit.android.resources.SystemResourceHold
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.resources.SystemResourceSummary
import kotlinx.coroutines.delay

/** Mirrors the desktop Status card: each hold with why and since when, and a way to release it. */
@Composable
internal fun ResourcesInUse(holds: List<SystemResourceHold>, actions: SettingsActions) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(holds.isEmpty()) {
        while (holds.isNotEmpty()) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
    }
    Text(stringResource(R.string.settings_resources_note), style = MaterialTheme.typography.bodyMedium)
    Text(
        SystemResourceSummary.headline(holds),
        style = MaterialTheme.typography.bodyLarge,
        modifier = Modifier
            .testTag(AutomationIds.RESOURCES_HEADLINE)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
    holds.forEach { hold ->
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                Text(hold.title, style = MaterialTheme.typography.titleSmall)
                Text(
                    "${hold.kind.displayName} · ${SystemResourceSummary.duration(hold.sinceMs, now)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(hold.reason, style = MaterialTheme.typography.bodySmall)
            }
            val releaseTitle = hold.releaseTitle
            if (releaseTitle != null) {
                val label = if (hold.isReleasing) {
                    stringResource(R.string.settings_resources_releasing)
                } else {
                    releaseTitle
                }
                val description = stringResource(R.string.settings_resources_release_label, label, hold.title)
                TextButton(
                    onClick = { actions.onReleaseResource(hold.id) },
                    enabled = !hold.isReleasing,
                    modifier = Modifier
                        .testTag(AutomationIds.resourceRelease(hold.kind, hold.owner))
                        .semantics { contentDescription = description },
                ) { Text(label) }
            }
        }
    }
    val canReleaseEverything = holds.any {
        it.isReleasable && !it.isReleasing && it.kind in SystemResourceRegistry.RELEASE_EVERYTHING_KINDS
    }
    Button(
        onClick = actions.onReleaseEverything,
        enabled = canReleaseEverything,
        modifier = Modifier.testTag(AutomationIds.RESOURCES_RELEASE_EVERYTHING),
    ) { Text(stringResource(R.string.settings_resources_release_everything)) }
    Text(
        stringResource(R.string.settings_resources_release_everything_hint),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}
