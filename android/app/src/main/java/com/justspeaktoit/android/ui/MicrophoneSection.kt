package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.AudioInput
import com.justspeaktoit.android.cloud.AudioInputChoice
import com.justspeaktoit.android.cloud.AudioInputKind

/** The microphone Cloud recordings use: the system default or one connected input. */
@Composable
internal fun MicrophoneSection(
    choice: AudioInputChoice,
    inputs: List<AudioInput>,
    onChoose: (String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        Text(
            stringResource(R.string.settings_microphone_title),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() },
        )
        Text(stringResource(R.string.settings_microphone_note), style = MaterialTheme.typography.bodyMedium)
        if (choice is AudioInputChoice.Unavailable) {
            Text(
                stringResource(R.string.microphone_unavailable),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier
                    .padding(top = 4.dp)
                    .testTag(AutomationIds.SETTINGS_MICROPHONE_UNAVAILABLE)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        Column(Modifier.selectableGroup()) {
            InputRow(
                label = stringResource(R.string.settings_microphone_default),
                detail = null,
                selected = choice is AudioInputChoice.SystemDefault,
                tag = AutomationIds.microphone(null),
                onClick = { onChoose(null) },
            )
            inputs.forEach { input ->
                InputRow(
                    label = input.label(),
                    detail = input.detail.takeIf { it.isNotBlank() },
                    selected = (choice as? AudioInputChoice.Selected)?.input?.id == input.id,
                    tag = AutomationIds.microphone(input.id),
                    onClick = { onChoose(input.id) },
                )
            }
        }
    }
}

@Composable
private fun InputRow(label: String, detail: String?, selected: Boolean, tag: String, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick),
    ) {
        RadioButton(selected = selected, onClick = null)
        Column(Modifier.padding(start = 8.dp)) {
            Text(label)
            if (detail != null) Text(detail, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun AudioInput.label(): String = stringResource(
    when (kind) {
        AudioInputKind.BuiltIn -> R.string.microphone_built_in
        AudioInputKind.Wired -> R.string.microphone_wired
        AudioInputKind.Usb -> R.string.microphone_usb
        AudioInputKind.Bluetooth -> R.string.microphone_bluetooth
    },
)
