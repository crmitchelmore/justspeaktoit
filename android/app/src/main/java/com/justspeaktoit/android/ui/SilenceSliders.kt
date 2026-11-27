package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.rememberSliderState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.SilenceSettings
import java.text.NumberFormat
import kotlin.math.roundToInt

/** How long the quiet must last, and how quiet counts as silence, for a Cloud recording to stop. */
@Composable
internal fun SilenceSliders(settings: SilenceSettings, onChange: (SilenceSettings) -> Unit) {
    val durationLabel = stringResource(R.string.settings_silence_duration)
    val durationValue = stringResource(R.string.settings_silence_duration_value, decimal(settings.durationSeconds, 1))
    val thresholdLabel = stringResource(R.string.settings_silence_threshold)
    val thresholdValue = decimal(settings.threshold, 2)
    val duration = SilenceSettings.DURATION_RANGE
    val threshold = SilenceSettings.THRESHOLD_RANGE
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("$durationLabel: $durationValue", style = MaterialTheme.typography.labelLarge)
        val durationState = rememberSliderState(
            value = settings.durationSeconds.toFloat(),
            trackRange = duration.start.toFloat()..duration.endInclusive.toFloat(),
            // Half-second steps from 0.5 to 5 seconds.
            steps = ((duration.endInclusive - duration.start) * 2).roundToInt() - 1,
        )
        durationState.value = settings.durationSeconds.toFloat()
        Slider(
            state = durationState,
            onValueChange = { onChange(settings.copy(durationSeconds = (it * 2).roundToInt() / 2.0)) },
            modifier = Modifier
                .testTag(AutomationIds.SETTINGS_SILENCE_DURATION)
                .semantics {
                    contentDescription = durationLabel
                    stateDescription = durationValue
                },
        )
        Text("$thresholdLabel: $thresholdValue", style = MaterialTheme.typography.labelLarge)
        val thresholdState = rememberSliderState(
            value = settings.threshold.toFloat(),
            trackRange = threshold.start.toFloat()..threshold.endInclusive.toFloat(),
        )
        thresholdState.value = settings.threshold.toFloat()
        Slider(
            state = thresholdState,
            onValueChange = { onChange(settings.copy(threshold = (it * 100).roundToInt() / 100.0)) },
            modifier = Modifier
                .testTag(AutomationIds.SETTINGS_SILENCE_THRESHOLD)
                .semantics {
                    contentDescription = thresholdLabel
                    stateDescription = thresholdValue
                },
        )
        Text(
            stringResource(R.string.settings_silence_threshold_note),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun decimal(value: Double, digits: Int): String = NumberFormat.getNumberInstance().apply {
    minimumFractionDigits = digits
    maximumFractionDigits = digits
}.format(value)
