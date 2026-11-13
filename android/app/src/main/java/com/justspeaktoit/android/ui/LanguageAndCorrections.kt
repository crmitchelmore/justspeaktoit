package com.justspeaktoit.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.dictation.DictationLanguage
import com.justspeaktoit.android.dictation.DictationLanguages

@Composable
private fun DictationLanguage.label(): String =
    if (isAutomatic) stringResource(R.string.language_automatic) else displayName

/** The saved dictation language under its section heading, opening a picker of the shared catalogue. */
@Composable
internal fun LanguageRow(languageId: String, onChoose: (String) -> Unit) {
    var picking by remember { mutableStateOf(false) }
    val title = stringResource(R.string.settings_language_title)
    val label = DictationLanguages.language(languageId).label()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.SETTINGS_LANGUAGE)
            .clickable(role = Role.Button) { picking = true }
            .semantics(mergeDescendants = true) { contentDescription = "$title, $label" }
            .padding(vertical = 8.dp),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.weight(1f),
        )
    }
    Text(stringResource(R.string.settings_language_note), style = MaterialTheme.typography.bodyMedium)
    if (picking) {
        AlertDialog(
            onDismissRequest = { picking = false },
            title = { Text(stringResource(R.string.language_picker_title)) },
            text = {
                LazyColumn(modifier = Modifier.heightIn(max = 420.dp)) {
                    items(DictationLanguages.all, key = { it.id }) { language ->
                        val selected = language.id == DictationLanguages.normalized(languageId)
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(AutomationIds.languageOption(language.id))
                                .selectable(selected = selected, role = Role.RadioButton) {
                                    onChoose(language.id)
                                    picking = false
                                }
                                .padding(vertical = 6.dp),
                        ) {
                            RadioButton(selected = selected, onClick = null)
                            Text(language.label(), modifier = Modifier.padding(start = 8.dp))
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { picking = false }) { Text(stringResource(R.string.action_cancel)) }
            },
        )
    }
}

/** Lists, adds and removes personal corrections; every change is saved at once. */
@Composable
internal fun CorrectionsEditor(rules: List<CorrectionRule>, onChange: (List<CorrectionRule>) -> Unit) {
    var writeAs by rememberSaveable { mutableStateOf("") }
    var heardAs by rememberSaveable { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.settings_corrections_note), style = MaterialTheme.typography.bodyMedium)
        if (rules.isEmpty()) {
            Text(
                stringResource(R.string.corrections_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        rules.forEach { rule ->
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                val heard = rule.heardAs.joinToString(", ").ifEmpty {
                    stringResource(R.string.corrections_vocabulary_only)
                }
                Text(
                    stringResource(R.string.corrections_rule, rule.writeAs, heard),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    onClick = { onChange(rules - rule) },
                    modifier = Modifier.testTag(AutomationIds.correctionRemove(rule.writeAs)),
                ) {
                    Icon(
                        painterResource(R.drawable.ic_close),
                        stringResource(R.string.corrections_remove, rule.writeAs),
                    )
                }
            }
        }
        OutlinedTextField(
            value = writeAs,
            onValueChange = { writeAs = it },
            label = { Text(stringResource(R.string.corrections_write_as)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth().testTag(AutomationIds.CORRECTIONS_WRITE_AS),
        )
        OutlinedTextField(
            value = heardAs,
            onValueChange = { heardAs = it },
            label = { Text(stringResource(R.string.corrections_heard_as)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Done),
            modifier = Modifier.fillMaxWidth().testTag(AutomationIds.CORRECTIONS_HEARD_AS),
        )
        OutlinedButton(
            onClick = {
                val rule = PersonalCorrections.rule(writeAs, heardAs) ?: return@OutlinedButton
                // A new rule for the same spelling replaces the old one.
                onChange(rules.filterNot { it.writeAs == rule.writeAs } + rule)
                writeAs = ""
                heardAs = ""
            },
            enabled = writeAs.isNotBlank(),
            modifier = Modifier.testTag(AutomationIds.CORRECTIONS_ADD),
        ) {
            Text(stringResource(R.string.corrections_add))
        }
    }
}
