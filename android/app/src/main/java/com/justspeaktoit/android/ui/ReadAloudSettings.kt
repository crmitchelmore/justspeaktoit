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
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.readaloud.CloudVoice
import com.justspeaktoit.android.readaloud.PronunciationDictionary
import com.justspeaktoit.android.readaloud.PronunciationEntry
import com.justspeaktoit.android.readaloud.PronunciationProblem
import com.justspeaktoit.android.readaloud.SystemSpeech
import com.justspeaktoit.android.readaloud.SystemVoice
import com.justspeaktoit.android.readaloud.VoiceCatalog
import com.justspeaktoit.android.readaloud.VoiceSelection
import com.justspeaktoit.android.readaloud.readVoiceCatalog

/** One choice in the voice picker. */
private data class VoiceOption(val selection: VoiceSelection, val label: String, val note: String?)

/** The read aloud voice under its heading, opening a picker of the phone's and the cloud voices. */
@Composable
internal fun ReadAloudVoiceRow(selection: String, savedCredentials: Set<String>, onChoose: (VoiceSelection) -> Unit) {
    val context = LocalContext.current.applicationContext
    val catalog = remember { runCatching { readVoiceCatalog(context) }.getOrNull() ?: VoiceCatalog(emptyList(), emptyList()) }
    var picking by remember { mutableStateOf(false) }
    val title = stringResource(R.string.settings_read_aloud_voice_title)
    val chosen = VoiceSelection.parse(selection)
    val label = when (chosen) {
        is VoiceSelection.System -> chosen.voiceName ?: stringResource(R.string.read_aloud_voice_system_default)
        is VoiceSelection.Cloud -> catalog.voice(chosen.key)?.let(::cloudLabel) ?: chosen.key
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.READ_ALOUD_VOICE)
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
    Text(stringResource(R.string.settings_read_aloud_voice_note), style = MaterialTheme.typography.bodyMedium)
    if (picking) {
        VoicePicker(chosen, catalog, savedCredentials, onDismiss = { picking = false }) {
            onChoose(it)
            picking = false
        }
    }
}

private fun cloudLabel(voice: CloudVoice) = "${voice.providerName} · ${voice.label}"

@Composable
private fun VoicePicker(
    chosen: VoiceSelection,
    catalog: VoiceCatalog,
    savedCredentials: Set<String>,
    onDismiss: () -> Unit,
    onChoose: (VoiceSelection) -> Unit,
) {
    val context = LocalContext.current.applicationContext
    val speech = remember { SystemSpeech(context) }
    var systemVoices by remember { mutableStateOf<List<SystemVoice>?>(null) }
    LaunchedEffect(speech) { systemVoices = speech.voices() }
    DisposableEffect(speech) { onDispose(speech::release) }
    val needsNetwork = stringResource(R.string.read_aloud_voice_needs_network)
    val groups = buildList {
        val phone = buildList {
            add(VoiceOption(VoiceSelection.System(), stringResource(R.string.read_aloud_voice_system_default), null))
            systemVoices.orEmpty().forEach {
                add(VoiceOption(VoiceSelection.System(it.name), it.label, needsNetwork.takeIf { _ -> it.needsNetwork }))
            }
        }
        add(stringResource(R.string.read_aloud_voice_system_group) to phone)
        catalog.providers.forEach { (provider, voices) ->
            val note = stringResource(R.string.read_aloud_voice_needs_key, provider)
            add(
                provider to voices.map { voice ->
                    VoiceOption(
                        VoiceSelection.Cloud(voice.key),
                        voice.label,
                        note.takeIf { voice.credentialId !in savedCredentials },
                    )
                },
            )
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.read_aloud_voice_picker_title)) },
        text = {
            LazyColumn(modifier = Modifier.heightIn(max = 480.dp)) {
                groups.forEach { (heading, options) ->
                    item(key = "heading.$heading") {
                        Text(
                            heading,
                            style = MaterialTheme.typography.titleSmall,
                            modifier = Modifier.padding(top = 12.dp, bottom = 4.dp).semantics { heading() },
                        )
                    }
                    items(options, key = { it.selection.encoded }) { option ->
                        VoiceOptionRow(option, selected = option.selection == chosen) { onChoose(option.selection) }
                    }
                }
                if (systemVoices == null) {
                    item(key = "loading") {
                        Text(stringResource(R.string.read_aloud_voice_loading), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.testTag(AutomationIds.READ_ALOUD_VOICE_CANCEL)) {
                Text(stringResource(R.string.action_cancel))
            }
        },
    )
}

@Composable
private fun VoiceOptionRow(option: VoiceOption, selected: Boolean, onSelect: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.readAloudVoiceOption(option.selection.encoded))
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .padding(vertical = 6.dp),
    ) {
        RadioButton(selected = selected, onClick = null)
        Column(modifier = Modifier.padding(start = 8.dp)) {
            Text(option.label)
            option.note?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Lists, adds and removes pronunciations; every change is saved at once. */
@Composable
internal fun PronunciationEditor(entries: List<PronunciationEntry>, onChange: (List<PronunciationEntry>) -> Unit) {
    var word by rememberSaveable { mutableStateOf("") }
    var sayAs by rememberSaveable { mutableStateOf("") }
    var caseSensitive by rememberSaveable { mutableStateOf(false) }
    var regex by rememberSaveable { mutableStateOf(false) }
    var problem by remember { mutableStateOf<PronunciationProblem?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.settings_pronunciation_note), style = MaterialTheme.typography.bodyMedium)
        if (entries.isEmpty()) {
            Text(
                stringResource(R.string.pronunciation_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        entries.forEachIndexed { index, entry ->
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                val spoken = entry.replacement?.takeIf { it.isNotEmpty() }
                Text(
                    if (spoken == null) {
                        stringResource(R.string.pronunciation_not_spoken, entry.word)
                    } else {
                        stringResource(R.string.pronunciation_entry, entry.word, spoken)
                    },
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    onClick = { onChange(entries - entry) },
                    modifier = Modifier.testTag(AutomationIds.pronunciationRemove(index)),
                ) {
                    Icon(painterResource(R.drawable.ic_close), stringResource(R.string.pronunciation_remove, entry.word))
                }
            }
        }
        OutlinedTextField(
            value = word,
            onValueChange = {
                word = it
                problem = null
            },
            label = { Text(stringResource(if (regex) R.string.pronunciation_pattern else R.string.pronunciation_word)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth().testTag(AutomationIds.PRONUNCIATION_WORD),
        )
        OutlinedTextField(
            value = sayAs,
            onValueChange = {
                sayAs = it
                problem = null
            },
            label = { Text(stringResource(R.string.pronunciation_say_as)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Done),
            modifier = Modifier.fillMaxWidth().testTag(AutomationIds.PRONUNCIATION_SAY_AS),
        )
        ToggleRow(stringResource(R.string.pronunciation_case_sensitive), caseSensitive, AutomationIds.PRONUNCIATION_CASE_SENSITIVE) {
            caseSensitive = it
        }
        ToggleRow(stringResource(R.string.pronunciation_regex), regex, AutomationIds.PRONUNCIATION_REGEX) {
            regex = it
            problem = null
        }
        problem?.let {
            Text(
                stringResource(
                    when (it) {
                        PronunciationProblem.Empty -> R.string.pronunciation_problem_empty
                        PronunciationProblem.Duplicate -> R.string.pronunciation_problem_duplicate
                        PronunciationProblem.InvalidPattern -> R.string.pronunciation_problem_pattern
                    },
                ),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.testTag(AutomationIds.PRONUNCIATION_PROBLEM),
            )
        }
        OutlinedButton(
            onClick = {
                val updated = PronunciationEdits.add(entries, word, sayAs, caseSensitive, regex)
                problem = PronunciationDictionary.validate(updated)
                if (problem == null) {
                    onChange(updated)
                    word = ""
                    sayAs = ""
                }
            },
            enabled = word.isNotBlank() && sayAs.isNotBlank(),
            modifier = Modifier.testTag(AutomationIds.PRONUNCIATION_ADD),
        ) {
            Text(stringResource(R.string.pronunciation_add))
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .toggleable(value = checked, role = Role.Switch, onValueChange = onChange)
            .padding(vertical = 4.dp),
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = null)
    }
}

/** Editing rules for the pronunciation dictionary, kept out of Compose so they can be tested. */
internal object PronunciationEdits {
    /**
     * [entries] with a new entry for [word] spoken as [sayAs]. An entry for the same word is replaced
     * in place and keeps its identity, so other devices see an update rather than a second entry.
     * A literal word is trimmed; a regular expression is kept exactly, as its spaces are part of it.
     */
    fun add(
        entries: List<PronunciationEntry>,
        word: String,
        sayAs: String,
        caseSensitive: Boolean,
        regex: Boolean,
    ): List<PronunciationEntry> {
        val entryWord = if (regex) word else word.trim()
        val spoken = sayAs.trim()
        val index = entries.indexOfFirst { it.word.equals(entryWord, ignoreCase = true) }
        val entry = PronunciationEntry(
            id = entries.getOrNull(index)?.id ?: PronunciationEntry.newId(),
            word = entryWord,
            pronunciation = spoken,
            replacement = spoken,
            category = entries.getOrNull(index)?.category,
            isRegex = regex,
            caseSensitive = caseSensitive,
        )
        return if (index < 0) entries + entry else entries.toMutableList().also { it[index] = entry }
    }
}
