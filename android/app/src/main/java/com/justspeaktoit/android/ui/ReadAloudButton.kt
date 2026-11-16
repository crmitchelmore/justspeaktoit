package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.justspeaktoit.android.R
import com.justspeaktoit.android.readaloud.AndroidReadAloudEngines
import com.justspeaktoit.android.readaloud.AndroidReadAloudFocus
import com.justspeaktoit.android.readaloud.PronunciationEntry
import com.justspeaktoit.android.readaloud.ReadAloudController
import com.justspeaktoit.android.readaloud.ReadAloudFailure
import com.justspeaktoit.android.readaloud.ReadAloudPhase
import com.justspeaktoit.android.readaloud.ReadAloudState
import com.justspeaktoit.android.readaloud.SystemSpeech
import com.justspeaktoit.android.readaloud.VoiceSelection
import com.justspeaktoit.android.security.KeystoreSecretStore
import kotlinx.coroutines.launch

/** The ids one set of read-aloud controls carries, derived from [read] so each set stays unique. */
internal data class ReadAloudTags(val read: String) {
    val pause: String get() = "$read.pause"
    val stop: String get() = "$read.stop"
    val status: String get() = "$read.status"
}

/**
 * One read-aloud player for a screen, released with it. A failure goes to [snackbar] and never moves to
 * another voice.
 */
@Composable
internal fun rememberReadAloudController(snackbar: SnackbarHostState): ReadAloudController {
    val context = LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()
    val system = remember { SystemSpeech(context) }
    val controller = remember {
        ReadAloudController(
            scope = scope,
            engines = AndroidReadAloudEngines(context, KeystoreSecretStore.create(context), system),
            focus = AndroidReadAloudFocus(context),
        )
    }
    DisposableEffect(controller) {
        onDispose {
            controller.stop()
            system.release()
        }
    }
    val state by controller.state.collectAsStateWithLifecycle()
    val message = state.failure?.let { failureMessage(it) }
    LaunchedEffect(state.failure) {
        if (message != null) {
            // Shown outside this effect, which clearing the failure restarts.
            scope.launch { snackbar.showSnackbar(message) }
            controller.dismissFailure()
        }
    }
    return controller
}

/**
 * Reads a finished transcript aloud with the chosen voice, the Android counterpart of the Mac's voice
 * output: read, pause, resume and stop.
 */
@Composable
internal fun ReadAloudButton(
    text: String,
    language: String?,
    voice: String,
    pronunciations: List<PronunciationEntry>,
    snackbar: SnackbarHostState,
) {
    val controller = rememberReadAloudController(snackbar)
    val state by controller.state.collectAsStateWithLifecycle()
    ReadAloudControls(
        state = state,
        tags = ReadAloudTags(AutomationIds.READ_ALOUD),
        onRead = { controller.speak(text, VoiceSelection.parse(voice), pronunciations, language) },
        controller = controller,
    )
}

/** Read, or pause/resume and stop while [state] is active, with a spoken status line. */
@Composable
internal fun ReadAloudControls(
    state: ReadAloudState,
    tags: ReadAloudTags,
    onRead: () -> Unit,
    controller: ReadAloudController,
    readEnabled: Boolean = true,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!state.active) {
                OutlinedButton(onClick = onRead, enabled = readEnabled, modifier = Modifier.testTag(tags.read)) {
                    Text(stringResource(R.string.action_read_aloud))
                }
            } else {
                val paused = state.phase == ReadAloudPhase.Paused
                OutlinedButton(
                    onClick = { if (paused) controller.resume() else controller.pause() },
                    modifier = Modifier.testTag(tags.pause),
                ) {
                    Text(stringResource(if (paused) R.string.action_resume_reading else R.string.action_pause_reading))
                }
                TextButton(onClick = controller::stop, modifier = Modifier.testTag(tags.stop)) {
                    Text(stringResource(R.string.action_stop_reading))
                }
            }
        }
        val status = when (state.phase) {
            ReadAloudPhase.Idle -> ""
            ReadAloudPhase.Preparing -> stringResource(R.string.read_aloud_preparing)
            ReadAloudPhase.Speaking -> stringResource(R.string.read_aloud_speaking)
            ReadAloudPhase.Paused -> stringResource(R.string.read_aloud_paused)
        }
        Text(
            status,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier
                .testTag(tags.status)
                .semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}

@Composable
private fun failureMessage(failure: ReadAloudFailure): String = when (failure) {
    is ReadAloudFailure.MissingKey -> stringResource(R.string.read_aloud_missing_key, failure.provider)
    is ReadAloudFailure.KeyUnreadable -> stringResource(R.string.read_aloud_key_unreadable, failure.provider)
    is ReadAloudFailure.KeyRejected -> stringResource(R.string.read_aloud_key_rejected, failure.provider)
    is ReadAloudFailure.OutOfCredit -> stringResource(R.string.read_aloud_out_of_credit, failure.provider)
    is ReadAloudFailure.RateLimited -> stringResource(R.string.read_aloud_rate_limited, failure.provider)
    is ReadAloudFailure.ServiceError -> stringResource(R.string.read_aloud_service_error, failure.provider, failure.status)
    is ReadAloudFailure.Unreachable -> stringResource(R.string.read_aloud_unreachable, failure.provider)
    is ReadAloudFailure.InvalidAudio -> stringResource(R.string.read_aloud_invalid_audio, failure.provider)
    is ReadAloudFailure.TooLong -> stringResource(R.string.read_aloud_too_long, failure.provider)
    ReadAloudFailure.VoiceUnavailable -> stringResource(R.string.read_aloud_voice_unavailable)
    ReadAloudFailure.SystemUnavailable -> stringResource(R.string.read_aloud_unavailable)
    ReadAloudFailure.AudioBusy -> stringResource(R.string.read_aloud_audio_busy)
    ReadAloudFailure.PlaybackFailed -> stringResource(R.string.read_aloud_playback_failed)
}
