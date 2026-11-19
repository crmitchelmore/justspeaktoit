package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.diagnostics.TroubleshootingFinding
import com.justspeaktoit.android.diagnostics.TroubleshootingFix
import com.justspeaktoit.android.diagnostics.TroubleshootingRules
import com.justspeaktoit.android.diagnostics.TroubleshootingSeverity

/** What only the Activity knows: the microphone permission and whether the keyboard is turned on. */
data class TroubleshootingFacts(
    val mic: MicPermission = MicPermission.NotRequested,
    val keyboardEnabled: Boolean = false,
)

/** The shared phone findings (SpeakCore's `MobileTroubleshooting`), problems first, each with its fixes. */
@Composable
internal fun TroubleshootingSection(
    findings: List<TroubleshootingFinding>,
    checking: Boolean,
    fixesFor: (TroubleshootingFinding) -> List<TroubleshootingFix>,
    onFix: (TroubleshootingFix) -> Unit,
) {
    Text(stringResource(R.string.settings_troubleshooting_note), style = MaterialTheme.typography.bodyMedium)
    val summary = if (checking) {
        R.string.settings_troubleshooting_checking
    } else {
        when (TroubleshootingRules.overall(findings)) {
            TroubleshootingSeverity.Issue -> R.string.settings_troubleshooting_summary_issue
            TroubleshootingSeverity.Warning -> R.string.settings_troubleshooting_summary_warning
            TroubleshootingSeverity.Info, TroubleshootingSeverity.Ok -> R.string.settings_troubleshooting_summary_ok
        }
    }
    Text(
        stringResource(summary),
        style = MaterialTheme.typography.bodyLarge,
        modifier = Modifier
            .testTag(AutomationIds.TROUBLESHOOTING_SUMMARY)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
    if (!checking) findings.forEach { finding -> FindingRow(finding, fixesFor(finding), onFix) }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FindingRow(
    finding: TroubleshootingFinding,
    fixes: List<TroubleshootingFix>,
    onFix: (TroubleshootingFix) -> Unit,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.fillMaxWidth().testTag(AutomationIds.troubleshootingFinding(finding.check.rawValue)),
    ) {
        val severity = stringResource(finding.severity.label)
        Text(
            stringResource(R.string.settings_troubleshooting_finding, severity, finding.title),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = finding.severity.color(),
        )
        Text(finding.detail, style = MaterialTheme.typography.bodyMedium)
        if (fixes.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                fixes.forEach { fix ->
                    val label = stringResource(fix.label)
                    val description = stringResource(R.string.settings_troubleshooting_fix_label, label, finding.title)
                    OutlinedButton(
                        onClick = { onFix(fix) },
                        modifier = Modifier
                            .testTag(AutomationIds.troubleshootingFix(finding.check.rawValue, fix.rawValue))
                            .semantics { contentDescription = description },
                    ) { Text(label) }
                }
            }
        }
    }
}

private val TroubleshootingSeverity.label: Int
    @StringRes get() = when (this) {
        TroubleshootingSeverity.Issue -> R.string.settings_troubleshooting_severity_issue
        TroubleshootingSeverity.Warning -> R.string.settings_troubleshooting_severity_warning
        TroubleshootingSeverity.Info -> R.string.settings_troubleshooting_severity_info
        TroubleshootingSeverity.Ok -> R.string.settings_troubleshooting_severity_ok
    }

@Composable
private fun TroubleshootingSeverity.color(): Color = when (this) {
    TroubleshootingSeverity.Issue -> MaterialTheme.colorScheme.error
    TroubleshootingSeverity.Warning -> MaterialTheme.colorScheme.tertiary
    TroubleshootingSeverity.Info -> MaterialTheme.colorScheme.onSurfaceVariant
    TroubleshootingSeverity.Ok -> MaterialTheme.colorScheme.primary
}

/** Only the fixes [com.justspeaktoit.android.diagnostics.AndroidTroubleshooting.fixes] offers are labelled. */
private val TroubleshootingFix.label: Int
    @StringRes get() = when (this) {
        TroubleshootingFix.RequestMicrophone -> R.string.settings_troubleshooting_fix_request_microphone
        TroubleshootingFix.OpenSystemSettings -> R.string.settings_troubleshooting_fix_app_settings
        TroubleshootingFix.OpenTranscriptionSettings -> R.string.settings_troubleshooting_fix_choose_mode
        TroubleshootingFix.OpenApiKeys, TroubleshootingFix.VerifyKey -> R.string.settings_troubleshooting_fix_api_keys
        TroubleshootingFix.DisablePostProcessing -> R.string.settings_troubleshooting_fix_cleanup_off
        TroubleshootingFix.OpenKeyboardSetup -> R.string.settings_troubleshooting_fix_keyboard
        TroubleshootingFix.RequestSpeechRecognition -> R.string.settings_troubleshooting_fix_request_microphone
    }
