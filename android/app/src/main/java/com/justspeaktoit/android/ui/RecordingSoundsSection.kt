package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.settings.RecordingSoundProfile
import com.justspeaktoit.android.settings.RecordingSoundSettings
import kotlin.math.roundToInt

/** The shared start/stop sound settings: on or off, profile and volume, with a sample to hear them. */
@Composable
internal fun RecordingSoundsSection(
    choice: RecordingSoundSettings,
    onChange: (RecordingSoundSettings) -> Unit,
    onPreview: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        Text(
            stringResource(R.string.settings_sounds_title),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() },
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.SETTINGS_SOUNDS_ENABLED)
                .toggleable(
                    value = choice.enabled,
                    role = Role.Switch,
                    onValueChange = { onChange(choice.copy(enabled = it)) },
                ),
        ) {
            Text(stringResource(R.string.settings_sounds_enabled), modifier = Modifier.weight(1f))
            Switch(checked = choice.enabled, onCheckedChange = null)
        }
        Text(stringResource(R.string.settings_sounds_note), style = MaterialTheme.typography.bodyMedium)
        if (!choice.enabled) return@Column

        Text(
            stringResource(R.string.settings_sounds_profile),
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(top = 8.dp),
        )
        RecordingSoundProfile.entries.forEach { profile ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(AutomationIds.soundProfile(profile.id))
                    .selectable(
                        selected = profile == choice.profile,
                        role = Role.RadioButton,
                        onClick = {
                            onChange(choice.copy(profile = profile))
                            onPreview()
                        },
                    ),
            ) {
                RadioButton(selected = profile == choice.profile, onClick = null)
                Text(profile.displayName, modifier = Modifier.padding(start = 8.dp))
            }
        }

        val volumeLabel = stringResource(R.string.settings_sounds_volume)
        val percent = stringResource(R.string.settings_sounds_volume_value, (choice.volume * 100).roundToInt())
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
            Text(volumeLabel, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            Text(percent, style = MaterialTheme.typography.bodyMedium)
        }
        Slider(
            value = choice.volume,
            onValueChange = { onChange(choice.copy(volume = it)) },
            onValueChangeFinished = onPreview,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.SETTINGS_SOUNDS_VOLUME)
                .semantics {
                    contentDescription = volumeLabel
                    stateDescription = percent
                },
        )
        TextButton(onClick = onPreview, modifier = Modifier.testTag(AutomationIds.SETTINGS_SOUNDS_PREVIEW)) {
            Text(stringResource(R.string.settings_sounds_preview))
        }
    }
}
