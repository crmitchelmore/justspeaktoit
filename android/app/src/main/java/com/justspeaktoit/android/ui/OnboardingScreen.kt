package com.justspeaktoit.android.ui

import androidx.activity.compose.BackHandler
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.onboarding.OnboardingStep
import kotlinx.coroutines.flow.StateFlow

/** What the guide can see of the system; refreshed whenever the app returns to the foreground. */
data class OnboardingStatus(
    val mic: MicPermission,
    val keyboardEnabled: Boolean,
    val tileAdded: Boolean,
)

class OnboardingActions(
    val onRequestMic: () -> Unit,
    val onOpenAppSettings: () -> Unit,
    val onOpenKeyboardSettings: () -> Unit,
    /** Null where Android cannot offer the tile in a dialog (before Android 13). */
    val onAddTile: (() -> Unit)?,
    val onFinish: () -> Unit,
    val dictation: DictationActions,
)

/** The first-run guide; also opened from Settings > Setup guide. */
@Composable
fun OnboardingScreen(
    state: DictationUiState,
    level: StateFlow<Float>,
    status: OnboardingStatus,
    actions: OnboardingActions,
) {
    var step by rememberSaveable { mutableStateOf(OnboardingStep.Welcome) }
    val busy = state.dictation.isActive
    step.previous?.let { previous -> BackHandler(enabled = !busy) { step = previous } }
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val progress = stringResource(R.string.onboarding_progress, step.position, OnboardingStep.count)
            Text(
                progress,
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.testTag(AutomationIds.ONBOARDING_PROGRESS)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
            LinearProgressIndicator(
                progress = { step.position.toFloat() / OnboardingStep.count },
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                stringResource(step.titleRes()),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.semantics { heading() },
            )
            Text(stringResource(step.detailRes()), style = MaterialTheme.typography.bodyLarge)
            StepContent(step, state, level, status, actions)
            StepButtons(
                step = step,
                busy = busy,
                onMove = { step = it },
                onFinish = actions.onFinish,
            )
        }
    }
}

@Composable
private fun StepContent(
    step: OnboardingStep,
    state: DictationUiState,
    level: StateFlow<Float>,
    status: OnboardingStatus,
    actions: OnboardingActions,
) {
    when (step) {
        OnboardingStep.Welcome, OnboardingStep.Done -> Unit
        OnboardingStep.Microphone -> MicrophoneStep(status.mic, actions)
        OnboardingStep.Route -> ModeSection(state, actions.dictation)
        OnboardingStep.Keyboard -> KeyboardStep(status, actions)
        OnboardingStep.TestDictation -> {
            TranscriptCard(state)
            RecordControls(state, level, actions.dictation)
        }
    }
}

@Composable
private fun MicrophoneStep(mic: MicPermission, actions: OnboardingActions) {
    when (mic) {
        MicPermission.Granted -> StatusLine(R.string.onboarding_microphone_granted)
        MicPermission.DeniedPermanently -> {
            Text(stringResource(R.string.permission_denied_settings), color = MaterialTheme.colorScheme.error)
            OutlinedButton(
                onClick = actions.onOpenAppSettings,
                modifier = Modifier.testTag(AutomationIds.ONBOARDING_OPEN_APP_SETTINGS),
            ) { Text(stringResource(R.string.action_open_settings)) }
        }
        MicPermission.NotRequested, MicPermission.Denied -> {
            if (mic == MicPermission.Denied) Text(stringResource(R.string.permission_rationale))
            Button(
                onClick = actions.onRequestMic,
                modifier = Modifier.testTag(AutomationIds.ONBOARDING_ALLOW_MIC),
            ) { Text(stringResource(R.string.onboarding_allow_microphone)) }
        }
    }
}

@Composable
private fun KeyboardStep(status: OnboardingStatus, actions: OnboardingActions) {
    StatusLine(
        if (status.keyboardEnabled) R.string.onboarding_keyboard_enabled else R.string.onboarding_keyboard_disabled,
    )
    OutlinedButton(
        onClick = actions.onOpenKeyboardSettings,
        modifier = Modifier.testTag(AutomationIds.ONBOARDING_KEYBOARD_SETTINGS),
    ) { Text(stringResource(R.string.onboarding_open_keyboard_settings)) }
    val addTile = actions.onAddTile
    when {
        status.tileAdded -> StatusLine(R.string.onboarding_tile_added)
        addTile != null -> OutlinedButton(
            onClick = addTile,
            modifier = Modifier.testTag(AutomationIds.ONBOARDING_ADD_TILE),
        ) { Text(stringResource(R.string.onboarding_add_tile)) }
        else -> Text(stringResource(R.string.onboarding_tile_manual), style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun StatusLine(@StringRes text: Int) {
    Text(
        stringResource(text),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}

@Composable
private fun StepButtons(step: OnboardingStep, busy: Boolean, onMove: (OnboardingStep) -> Unit, onFinish: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        val previous = step.previous
        if (previous != null) {
            TextButton(
                onClick = { onMove(previous) },
                enabled = !busy,
                modifier = Modifier.testTag(AutomationIds.ONBOARDING_BACK),
            ) { Text(stringResource(R.string.action_back)) }
        } else {
            TextButton(onClick = onFinish, modifier = Modifier.testTag(AutomationIds.ONBOARDING_SKIP)) {
                Text(stringResource(R.string.onboarding_skip))
            }
        }
        Spacer(Modifier.weight(1f))
        val next = step.next
        Button(
            onClick = { if (next != null) onMove(next) else onFinish() },
            enabled = !busy,
            modifier = Modifier.testTag(AutomationIds.ONBOARDING_NEXT),
        ) { Text(stringResource(if (next != null) R.string.onboarding_next else R.string.onboarding_finish)) }
    }
}

@StringRes
private fun OnboardingStep.titleRes(): Int = when (this) {
    OnboardingStep.Welcome -> R.string.onboarding_welcome_title
    OnboardingStep.Microphone -> R.string.onboarding_microphone_title
    OnboardingStep.Route -> R.string.onboarding_route_title
    OnboardingStep.Keyboard -> R.string.onboarding_keyboard_title
    OnboardingStep.TestDictation -> R.string.onboarding_test_title
    OnboardingStep.Done -> R.string.onboarding_done_title
}

@StringRes
private fun OnboardingStep.detailRes(): Int = when (this) {
    OnboardingStep.Welcome -> R.string.onboarding_welcome_detail
    OnboardingStep.Microphone -> R.string.onboarding_microphone_detail
    OnboardingStep.Route -> R.string.onboarding_route_detail
    OnboardingStep.Keyboard -> R.string.onboarding_keyboard_detail
    OnboardingStep.TestDictation -> R.string.onboarding_test_detail
    OnboardingStep.Done -> R.string.onboarding_done_detail
}
