package com.justspeaktoit.android.ui

import android.content.ActivityNotFoundException
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.justspeaktoit.android.R
import com.justspeaktoit.android.diagnostics.IssueFacts
import com.justspeaktoit.android.diagnostics.IssueReport
import com.justspeaktoit.android.output.TranscriptOutput

/**
 * Previews the exact issue draft before anything is shared (issue #1633). The user consents per
 * report by choosing Copy or Open; neither attaches or submits anything on their behalf.
 */
@Composable
fun IssueReportDialog(facts: IssueFacts, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    var include by rememberSaveable { mutableStateOf(true) }
    var status by remember { mutableStateOf<Int?>(null) }
    val report = remember(facts, include) {
        IssueReport.build(facts, if (include) emptySet() else IssueReport.Section.entries.toSet())
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(modifier = Modifier.fillMaxSize().testTag(AutomationIds.ISSUE_REPORT)) {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    stringResource(R.string.issue_report_title),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.semantics { heading() },
                )
                Text(stringResource(R.string.issue_report_intro), style = MaterialTheme.typography.bodyMedium)
                IncludeDiagnosticsRow(include) {
                    include = it
                    status = null
                }
                Text(
                    stringResource(R.string.issue_report_draft),
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.semantics { heading() },
                )
                Text(report.title, style = MaterialTheme.typography.titleMedium)
                SelectionContainer {
                    Text(
                        report.body,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.testTag(AutomationIds.ISSUE_REPORT_DRAFT),
                    )
                }
                status?.let { StatusText(it) }
                if (report.issueUrl == null) StatusText(R.string.issue_report_too_long)
                Button(
                    onClick = {
                        TranscriptOutput.copy(context, "${report.title}\n\n${report.body}")
                        status = R.string.issue_report_copied
                    },
                    modifier = Modifier.fillMaxWidth().testTag(AutomationIds.ISSUE_REPORT_COPY),
                ) { Text(stringResource(R.string.issue_report_copy)) }
                OutlinedButton(
                    onClick = {
                        val url = report.issueUrl ?: return@OutlinedButton
                        status = try {
                            uriHandler.openUri(url)
                            R.string.issue_report_opened
                        } catch (e: IllegalArgumentException) {
                            // Compose reports a missing browser as an IllegalArgumentException.
                            R.string.issue_report_open_failed
                        } catch (e: ActivityNotFoundException) {
                            R.string.issue_report_open_failed
                        }
                    },
                    enabled = report.issueUrl != null,
                    modifier = Modifier.fillMaxWidth().testTag(AutomationIds.ISSUE_REPORT_OPEN),
                ) { Text(stringResource(R.string.issue_report_open)) }
                TextButton(
                    onClick = onDismiss,
                    modifier = Modifier.fillMaxWidth().testTag(AutomationIds.ISSUE_REPORT_CLOSE),
                ) { Text(stringResource(R.string.issue_report_close)) }
            }
        }
    }
}

@Composable
private fun IncludeDiagnosticsRow(include: Boolean, onChange: (Boolean) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.ISSUE_REPORT_INCLUDE)
                .toggleable(value = include, role = Role.Switch, onValueChange = onChange),
        ) {
            Text(
                stringResource(R.string.issue_report_include),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            Switch(checked = include, onCheckedChange = null)
        }
        Text(
            stringResource(R.string.issue_report_include_note),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun StatusText(@StringRes message: Int) {
    Text(
        stringResource(message),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}
