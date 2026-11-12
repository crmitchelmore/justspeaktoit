package com.justspeaktoit.android.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.justspeaktoit.android.R
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.ui.theme.BrandAccentDeep
import com.justspeaktoit.android.ui.theme.BrandAccentWarm
import kotlinx.coroutines.flow.StateFlow

/** The record/stop button, its live level halo and the cancel action while a session runs. */
@Composable
internal fun RecordControls(state: DictationUiState, level: StateFlow<Float>, actions: DictationActions) {
    val active = state.dictation.isActive
    val enabled = active || state.canStart
    val description = stringResource(if (active) R.string.action_stop else R.string.action_start)
    Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(132.dp)) {
            if (active) LevelHalo(level)
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(96.dp)
                    .clip(CircleShape)
                    .background(
                        if (enabled) {
                            Brush.linearGradient(listOf(BrandAccentDeep, BrandAccentWarm))
                        } else {
                            SolidColor(MaterialTheme.colorScheme.outline)
                        },
                    )
                    .testTag(AutomationIds.RECORD)
                    .clickable(enabled = enabled) { if (active) actions.onStop() else actions.onRecordTapped() }
                    .semantics {
                        role = Role.Button
                        contentDescription = description
                    },
            ) {
                Icon(
                    painter = painterResource(if (active) R.drawable.ic_stop else R.drawable.ic_mic),
                    // Decorative: the enclosing button carries the Start/Stop label.
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(40.dp),
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        if (active) {
            TextButton(onClick = actions.onCancel, modifier = Modifier.testTag(AutomationIds.CANCEL)) {
                Text(stringResource(R.string.action_cancel))
            }
        }
    }
}

@Composable
private fun LevelHalo(level: StateFlow<Float>) {
    val rms by level.collectAsStateWithLifecycle()
    // Recognisers report roughly -2..10 dB; map that onto a gentle 1.0..1.35 scale.
    val target = 1f + ((rms + 2f) / 12f).coerceIn(0f, 1f) * 0.35f
    val scale by animateFloatAsState(target, label = "level")
    Box(
        modifier = Modifier
            .size(96.dp)
            .scale(scale)
            .clip(CircleShape)
            .background(BrandAccentWarm.copy(alpha = 0.3f)),
    )
}
