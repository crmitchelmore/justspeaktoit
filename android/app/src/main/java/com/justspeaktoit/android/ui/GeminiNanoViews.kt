package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.ondevice.GeminiNanoAvailability
import com.justspeaktoit.android.ondevice.GeminiNanoFailure

/** Whether this phone offers Gemini Nano, and the actions to check it and download it, for the cleanup pickers. */
class GeminiNanoUi(
    val availability: GeminiNanoAvailability = GeminiNanoAvailability.Unchecked,
    val onCheck: () -> Unit = {},
    val onDownload: () -> Unit = {},
)

/** What the user is told when Gemini Nano kept the original transcript or is not offered. */
@StringRes
internal fun GeminiNanoFailure.message(): Int = when (this) {
    GeminiNanoFailure.NotInForeground -> R.string.gemini_nano_not_in_foreground
    GeminiNanoFailure.Busy -> R.string.gemini_nano_busy
    GeminiNanoFailure.QuotaExceeded -> R.string.gemini_nano_quota
    GeminiNanoFailure.TooLong -> R.string.gemini_nano_too_long
    GeminiNanoFailure.NotDownloaded -> R.string.gemini_nano_not_downloaded
    GeminiNanoFailure.Unavailable -> R.string.gemini_nano_unavailable
    GeminiNanoFailure.NeedsSystemUpdate -> R.string.gemini_nano_needs_update
    GeminiNanoFailure.NotEnoughStorage -> R.string.gemini_nano_storage
    GeminiNanoFailure.NoReply -> R.string.gemini_nano_no_reply
    GeminiNanoFailure.Failed -> R.string.gemini_nano_failed
}

/**
 * The cleanup picker's **On this phone** section. Gemini Nano is listed only where AICore offers it;
 * elsewhere a line says why. Choosing it while it still needs downloading starts the download.
 */
@Composable
internal fun GeminiNanoPickerSection(ui: GeminiNanoUi, isSelected: Boolean, onChoose: () -> Unit) {
    val availability = ui.availability
    Text(
        stringResource(R.string.cleanup_picker_on_device_heading),
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier
            .padding(vertical = 8.dp)
            .semantics { heading() },
    )
    if (availability.offered) {
        val model = CloudCatalog.geminiNano
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.CLEANUP_PICKER.model(model.selectionId))
                .selectable(
                    selected = isSelected,
                    role = Role.RadioButton,
                    onClick = {
                        if (availability is GeminiNanoAvailability.Downloadable ||
                            availability is GeminiNanoAvailability.DownloadFailed
                        ) {
                            ui.onDownload()
                        }
                        onChoose()
                    },
                )
                .padding(vertical = 8.dp),
        ) {
            RadioButton(selected = isSelected, onClick = null)
            Column(modifier = Modifier.padding(start = 12.dp).weight(1f)) {
                Text(model.displayName, style = MaterialTheme.typography.bodyLarge)
                Text(
                    geminiNanoStatus(availability),
                    style = MaterialTheme.typography.bodySmall,
                    color = if (availability is GeminiNanoAvailability.DownloadFailed) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
    } else {
        Text(
            geminiNanoStatus(availability),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.CLEANUP_PICKER_GEMINI_NANO_STATUS)
                .semantics { liveRegion = LiveRegionMode.Polite }
                .padding(vertical = 8.dp),
        )
    }
    HorizontalDivider()
}

/** Gemini Nano's state under the cleanup model row while it is the chosen cleanup model. */
@Composable
internal fun GeminiNanoSettingsNote(availability: GeminiNanoAvailability, onCheck: () -> Unit) {
    LaunchedEffect(Unit) { onCheck() }
    Text(
        geminiNanoStatus(availability),
        style = MaterialTheme.typography.bodySmall,
        color = if (availability.offered && availability !is GeminiNanoAvailability.DownloadFailed) {
            MaterialTheme.colorScheme.onSurfaceVariant
        } else {
            MaterialTheme.colorScheme.error
        },
        modifier = Modifier
            .testTag(AutomationIds.SETTINGS_CLEANUP_GEMINI_NANO_STATUS)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
}

/** Gemini Nano's state in one line, for the picker and Settings. */
@Composable
internal fun geminiNanoStatus(availability: GeminiNanoAvailability): String = when (availability) {
    GeminiNanoAvailability.Unchecked, GeminiNanoAvailability.Checking -> stringResource(R.string.gemini_nano_checking)
    GeminiNanoAvailability.Available -> stringResource(R.string.gemini_nano_ready)
    GeminiNanoAvailability.Downloadable -> stringResource(R.string.gemini_nano_downloadable)
    is GeminiNanoAvailability.Downloading -> if (availability.totalBytes > 0) {
        val percent = (availability.downloadedBytes * PERCENT / availability.totalBytes).coerceIn(0, PERCENT).toInt()
        stringResource(R.string.gemini_nano_downloading_percent, percent)
    } else {
        stringResource(R.string.gemini_nano_downloading)
    }
    is GeminiNanoAvailability.DownloadFailed ->
        stringResource(R.string.gemini_nano_download_failed, stringResource(availability.reason.message()))
    is GeminiNanoAvailability.Unavailable ->
        stringResource(R.string.gemini_nano_not_offered, stringResource(availability.reason.message()))
}

private const val PERCENT = 100L
