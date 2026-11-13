package com.justspeaktoit.android.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.settings.RawConfiguration
import com.justspeaktoit.android.settings.RawConfigurationReport
import com.justspeaktoit.android.settings.RawConfigurationSchema
import com.justspeaktoit.android.settings.RawConfigurationValues
import java.io.IOException

/** What the editor last did, for its status line; announced politely to screen readers. */
private data class EditorOutcome(val message: String, val report: RawConfigurationReport? = null)

/**
 * Every setting as JSON (SpeakCore's raw-configuration document): validate, apply all or none,
 * import, export and reset to defaults. API keys appear only as whether each is stored.
 */
@Composable
fun RawConfigurationEditor(state: DictationUiState, onApply: (Map<String, Any?>) -> Boolean) {
    val context = LocalContext.current
    val schema = remember {
        context.assets.open(RawConfigurationSchema.ASSET).bufferedReader().use {
            RawConfigurationSchema.fromJson(it.readText())
        }
    }
    val prefs = remember { AppPreferences(context) }
    val apiKeys = CloudCatalog.providers.associate { it.credentialId to (it in state.savedKeys) }
    fun currentDocument() = RawConfiguration.document(
        schema, RawConfigurationValues.of(state), apiKeys, prefs.otherPlatformSettings,
    )
    var text by rememberSaveable { mutableStateOf("") }
    var outcome by remember { mutableStateOf<EditorOutcome?>(null) }
    var confirmReset by remember { mutableStateOf(false) }

    val validMessage = stringResource(R.string.raw_config_valid)
    val invalidMessage = stringResource(R.string.raw_config_invalid)
    val appliedMessage = stringResource(R.string.raw_config_applied)
    val unchangedMessage = stringResource(R.string.raw_config_unchanged)
    val busyMessage = stringResource(R.string.raw_config_busy)
    val resetMessage = stringResource(R.string.raw_config_reset_done)
    val exportedMessage = stringResource(R.string.raw_config_exported)
    val importedMessage = stringResource(R.string.raw_config_imported)
    val fileErrorMessage = stringResource(R.string.raw_config_file_error)

    fun validate(document: String): RawConfigurationReport =
        RawConfiguration.validate(schema, document, RawConfigurationValues.of(state))

    /** Applies [document] all or none; returns the message to show. */
    fun apply(document: String, successMessage: String): EditorOutcome {
        val report = validate(document)
        if (!report.isValid) return EditorOutcome(invalidMessage, report)
        if (!onApply(report.changes)) return EditorOutcome(busyMessage, report)
        prefs.otherPlatformSettings = prefs.otherPlatformSettings + report.otherPlatformSettings
        return EditorOutcome(if (report.changes.isEmpty()) unchangedMessage else successMessage, report)
    }

    val exportFile = ActivityResultContracts.CreateDocument("application/json")
    val exporter = rememberLauncherForActivityResult(exportFile) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        outcome = try {
            context.contentResolver.openOutputStream(uri)?.use { it.write(currentDocument().toByteArray()) }
                ?: throw IOException("No output stream")
            EditorOutcome(exportedMessage)
        } catch (e: IOException) {
            EditorOutcome(fileErrorMessage)
        } catch (e: SecurityException) {
            EditorOutcome(fileErrorMessage)
        }
    }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        outcome = try {
            val imported = context.contentResolver.openInputStream(uri)?.use { stream ->
                String(stream.readNBytesCompat(MAX_DOCUMENT_BYTES))
            } ?: throw IOException("No input stream")
            text = imported
            val report = validate(imported)
            EditorOutcome(if (report.isValid) importedMessage else invalidMessage, report)
        } catch (e: IOException) {
            EditorOutcome(fileErrorMessage)
        } catch (e: SecurityException) {
            EditorOutcome(fileErrorMessage)
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.settings_raw_config_note), style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(
            value = text,
            onValueChange = { text = it },
            label = { Text(stringResource(R.string.raw_config_editor_label)) },
            placeholder = { Text(stringResource(R.string.raw_config_editor_placeholder)) },
            textStyle = TextStyle(fontFamily = FontFamily.Monospace),
            minLines = 6,
            maxLines = 16,
            modifier = Modifier.fillMaxWidth().testTag(AutomationIds.RAW_CONFIG_EDITOR),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = {
                    text = currentDocument()
                    outcome = null
                },
                modifier = Modifier.weight(1f).testTag(AutomationIds.RAW_CONFIG_LOAD),
            ) { Text(stringResource(R.string.raw_config_load)) }
            OutlinedButton(
                onClick = {
                    val report = validate(text)
                    outcome = EditorOutcome(if (report.isValid) validMessage else invalidMessage, report)
                },
                enabled = text.isNotBlank(),
                modifier = Modifier.weight(1f).testTag(AutomationIds.RAW_CONFIG_VALIDATE),
            ) { Text(stringResource(R.string.raw_config_validate)) }
            OutlinedButton(
                onClick = { outcome = apply(text, appliedMessage) },
                enabled = text.isNotBlank(),
                modifier = Modifier.weight(1f).testTag(AutomationIds.RAW_CONFIG_APPLY),
            ) { Text(stringResource(R.string.raw_config_apply)) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = { importer.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) },
                modifier = Modifier.weight(1f).testTag(AutomationIds.RAW_CONFIG_IMPORT),
            ) { Text(stringResource(R.string.raw_config_import)) }
            OutlinedButton(
                onClick = { exporter.launch("JustSpeakToIt-settings.json") },
                modifier = Modifier.weight(1f).testTag(AutomationIds.RAW_CONFIG_EXPORT),
            ) { Text(stringResource(R.string.raw_config_export)) }
            OutlinedButton(
                onClick = { confirmReset = true },
                modifier = Modifier.weight(1f).testTag(AutomationIds.RAW_CONFIG_RESET),
            ) { Text(stringResource(R.string.raw_config_reset)) }
        }
        outcome?.let { current ->
            Column(
                verticalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(AutomationIds.RAW_CONFIG_STATUS)
                    .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
            ) {
                val failed = current.report?.isValid == false || current.message == fileErrorMessage ||
                    current.message == busyMessage
                Text(
                    current.message,
                    style = MaterialTheme.typography.titleSmall,
                    color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                )
                current.report?.errors?.forEach {
                    Text(
                        it.toString(),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                current.report?.warnings?.forEach {
                    Text(it.toString(), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text(stringResource(R.string.raw_config_reset_title)) },
            text = { Text(stringResource(R.string.raw_config_reset_confirm)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmReset = false
                        val defaults = RawConfiguration.document(schema, schema.defaults, apiKeys)
                        outcome = apply(defaults, resetMessage)
                        if (outcome?.report?.isValid == true) text = ""
                    },
                    modifier = Modifier.testTag(AutomationIds.RAW_CONFIG_RESET_CONFIRM),
                ) { Text(stringResource(R.string.raw_config_reset)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmReset = false }) { Text(stringResource(R.string.action_cancel)) }
            },
        )
    }
}

/** Larger files are not settings documents; reading stops here rather than exhausting memory. */
private const val MAX_DOCUMENT_BYTES = 1_000_000

private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
    val buffer = java.io.ByteArrayOutputStream()
    val chunk = ByteArray(8_192)
    while (buffer.size() < limit) {
        val read = read(chunk, 0, minOf(chunk.size, limit - buffer.size()))
        if (read < 0) break
        buffer.write(chunk, 0, read)
    }
    return buffer.toByteArray()
}
