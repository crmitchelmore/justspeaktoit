package com.justspeaktoit.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CleanupModelPicker
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.dictation.DictationLanguages
import com.justspeaktoit.android.settings.DictationProfile

/**
 * Chooses the active profile on the dictation screen. Hidden until a profile exists, and disabled
 * while dictating so a running session keeps the settings it started with.
 */
@Composable
internal fun ProfileChooser(
    profiles: List<DictationProfile>,
    active: DictationProfile?,
    sessionActive: Boolean,
    onChoose: (String?) -> Unit,
) {
    if (profiles.isEmpty()) return
    var open by remember { mutableStateOf(false) }
    val name = active?.name ?: stringResource(R.string.profile_none)
    Box {
        OutlinedButton(
            onClick = { open = true },
            enabled = !sessionActive,
            modifier = Modifier
                .testTag(AutomationIds.PROFILE_CHOOSER)
                .semantics { liveRegion = LiveRegionMode.Polite },
        ) {
            Text(stringResource(R.string.profile_label, name))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.profile_none)) },
                onClick = {
                    onChoose(null)
                    open = false
                },
                modifier = Modifier.testTag(AutomationIds.PROFILE_CHOOSER_NONE),
            )
            profiles.forEachIndexed { index, profile ->
                DropdownMenuItem(
                    text = { Text(profile.name) },
                    onClick = {
                        onChoose(profile.id)
                        open = false
                    },
                    modifier = Modifier.testTag(AutomationIds.profileOption(index)),
                )
            }
        }
    }
}

/** Lists the saved profiles in Settings; each opens the editor, and Add creates a new one. */
@Composable
internal fun ProfilesEditor(
    profiles: List<DictationProfile>,
    activeId: String?,
    savedKeys: Set<CloudProvider>,
    onSave: (DictationProfile) -> Unit,
    onDelete: (String) -> Unit,
) {
    var editing by remember { mutableStateOf<DictationProfile?>(null) }
    var creating by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.settings_profiles_note), style = MaterialTheme.typography.bodyMedium)
        if (profiles.isEmpty()) {
            Text(
                stringResource(R.string.profiles_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        profiles.forEachIndexed { index, profile ->
            val active = profile.id == activeId
            val label = if (active) stringResource(R.string.profile_active, profile.name) else profile.name
            val description = stringResource(R.string.profile_edit, label)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(AutomationIds.profileEdit(index))
                    .clickable(role = Role.Button) { editing = profile }
                    .semantics(mergeDescendants = true) { contentDescription = description }
                    .padding(vertical = 8.dp),
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        OutlinedButton(
            onClick = { creating = true },
            modifier = Modifier.testTag(AutomationIds.SETTINGS_PROFILE_ADD),
        ) {
            Text(stringResource(R.string.action_add_profile))
        }
    }
    val current = editing
    if (current != null || creating) {
        ProfileEditorDialog(
            initial = current,
            savedKeys = savedKeys,
            onSave = {
                onSave(it)
                editing = null
                creating = false
            },
            onDelete = current?.let { profile ->
                {
                    onDelete(profile.id)
                    editing = null
                }
            },
            onDismiss = {
                editing = null
                creating = false
            },
        )
    }
}

/** One choice inside the profile editor. */
private data class Choice(val key: String?, val label: String)

@Composable
private fun ProfileEditorDialog(
    initial: DictationProfile?,
    savedKeys: Set<CloudProvider>,
    onSave: (DictationProfile) -> Unit,
    onDelete: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    val base = remember(initial) { initial ?: DictationProfile.create("") }
    var name by rememberSaveable(base.id) { mutableStateOf(base.name) }
    var cloudModelId by rememberSaveable(base.id) { mutableStateOf(base.cloudModel?.catalogId) }
    var cloudModelChanged by rememberSaveable(base.id) { mutableStateOf(false) }
    var languageId by rememberSaveable(base.id) { mutableStateOf(base.language) }
    var cleanupEnabled by rememberSaveable(base.id) { mutableStateOf(base.cleanupEnabled) }
    var cleanupModelId by rememberSaveable(base.id) { mutableStateOf(base.cleanupModel?.selectionId) }
    var prompt by rememberSaveable(base.id) { mutableStateOf(base.cleanupPrompt.orEmpty()) }
    var picking by remember { mutableStateOf<String?>(null) }

    val useSettings = stringResource(R.string.profile_use_settings)
    val otherDevice = base.transcriptionModelId?.takeIf { base.cloudModel == null && !cloudModelChanged }
    val cloudLabel = CloudCatalog.transcriptionModels.firstOrNull { it.catalogId == cloudModelId }?.displayName
        ?: otherDevice?.let { stringResource(R.string.profile_model_elsewhere, it) }
        ?: useSettings
    val languageLabel = languageId?.let { id ->
        DictationLanguages.language(id).let {
            if (it.isAutomatic) stringResource(R.string.language_automatic) else it.displayName
        }
    } ?: useSettings
    val cleanupLabel = when (cleanupEnabled) {
        true -> stringResource(R.string.profile_cleanup_on)
        false -> stringResource(R.string.profile_cleanup_off)
        null -> useSettings
    }
    val cleanupModelLabel = cleanupModelId?.let { CleanupModelPicker.selectionLabel(CloudCatalog.cleanupModel(it)) }
        ?: useSettings

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(stringResource(if (initial == null) R.string.profile_editor_new else R.string.profile_editor_edit))
        },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.profile_name)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                    modifier = Modifier.fillMaxWidth().testTag(AutomationIds.PROFILE_EDITOR_NAME),
                )
                EditorChoiceRow(
                    stringResource(R.string.profile_cloud_model),
                    cloudLabel,
                    Modifier.testTag(AutomationIds.PROFILE_EDITOR_CLOUD_MODEL),
                ) { picking = CLOUD_MODEL }
                Text(stringResource(R.string.profile_cloud_model_note), style = MaterialTheme.typography.bodySmall)
                EditorChoiceRow(
                    stringResource(R.string.profile_language),
                    languageLabel,
                    Modifier.testTag(AutomationIds.PROFILE_EDITOR_LANGUAGE),
                ) { picking = LANGUAGE }
                EditorChoiceRow(
                    stringResource(R.string.profile_cleanup),
                    cleanupLabel,
                    Modifier.testTag(AutomationIds.PROFILE_EDITOR_CLEANUP),
                ) { picking = CLEANUP }
                EditorChoiceRow(
                    stringResource(R.string.profile_cleanup_model),
                    cleanupModelLabel,
                    Modifier.testTag(AutomationIds.PROFILE_EDITOR_CLEANUP_MODEL),
                ) { picking = CLEANUP_MODEL }
                if (cleanupModelId != null) {
                    TextButton(
                        onClick = { cleanupModelId = null },
                        modifier = Modifier.testTag(AutomationIds.PROFILE_EDITOR_CLEANUP_MODEL_RESET),
                    ) {
                        Text(stringResource(R.string.profile_cleanup_model_use_settings))
                    }
                }
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { prompt = it },
                    label = { Text(stringResource(R.string.profile_cleanup_prompt)) },
                    supportingText = { Text(stringResource(R.string.profile_cleanup_prompt_note)) },
                    minLines = 3,
                    modifier = Modifier.fillMaxWidth().testTag(AutomationIds.PROFILE_EDITOR_PROMPT),
                )
                if (onDelete != null) {
                    TextButton(
                        onClick = onDelete,
                        modifier = Modifier.testTag(AutomationIds.PROFILE_EDITOR_DELETE),
                    ) {
                        Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    // Values Android cannot show, such as another device's model, are kept unless changed.
                    val saved = base.copy(
                        name = name.trim(),
                        languageId = if (languageId == base.language) base.languageId else languageId,
                        cleanupEnabled = cleanupEnabled,
                        cleanupModelId = if (cleanupModelId == base.cleanupModel?.selectionId) {
                            base.cleanupModelId
                        } else {
                            cleanupModelId
                        },
                        cleanupPrompt = prompt.takeIf { it.isNotBlank() },
                    )
                    val model = CloudCatalog.transcriptionModels.firstOrNull { it.catalogId == cloudModelId }
                    onSave(if (cloudModelChanged) saved.withCloudModel(model) else saved)
                },
                enabled = name.isNotBlank(),
                modifier = Modifier.testTag(AutomationIds.PROFILE_EDITOR_SAVE),
            ) {
                Text(stringResource(R.string.action_save))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        },
    )

    when (picking) {
        CLOUD_MODEL -> ChoiceDialog(
            title = stringResource(R.string.profile_cloud_model),
            choices = listOf(Choice(null, useSettings)) +
                CloudCatalog.transcriptionModels.map { Choice(it.catalogId, it.displayName) },
            selected = cloudModelId,
            onChoose = {
                cloudModelId = it
                cloudModelChanged = true
                picking = null
            },
            onDismiss = { picking = null },
        )
        LANGUAGE -> ChoiceDialog(
            title = stringResource(R.string.profile_language),
            choices = listOf(Choice(null, useSettings)) + DictationLanguages.all.map {
                Choice(it.id, if (it.isAutomatic) stringResource(R.string.language_automatic) else it.displayName)
            },
            selected = languageId,
            onChoose = {
                languageId = it
                picking = null
            },
            onDismiss = { picking = null },
        )
        CLEANUP -> ChoiceDialog(
            title = stringResource(R.string.profile_cleanup),
            choices = listOf(
                Choice(null, useSettings),
                Choice(ON, stringResource(R.string.profile_cleanup_on)),
                Choice(OFF, stringResource(R.string.profile_cleanup_off)),
            ),
            selected = when (cleanupEnabled) {
                true -> ON
                false -> OFF
                null -> null
            },
            onChoose = {
                cleanupEnabled = when (it) {
                    ON -> true
                    OFF -> false
                    else -> null
                }
                picking = null
            },
            onDismiss = { picking = null },
        )
        CLEANUP_MODEL -> CleanupModelPickerDialog(
            selected = CloudCatalog.cleanupModel(cleanupModelId),
            savedKeys = savedKeys,
            onChoose = {
                cleanupModelId = it.selectionId
                picking = null
            },
            onDismiss = { picking = null },
        )
    }
}

@Composable
private fun EditorChoiceRow(title: String, value: String, modifier: Modifier, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = "$title, $value" }
            .padding(vertical = 6.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun ChoiceDialog(
    title: String,
    choices: List<Choice>,
    selected: String?,
    onChoose: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            LazyColumn(modifier = Modifier.heightIn(max = 420.dp)) {
                items(choices, key = { it.key ?: "" }) { choice ->
                    val isSelected = choice.key == selected
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(selected = isSelected, role = Role.RadioButton) { onChoose(choice.key) }
                            .padding(vertical = 6.dp),
                    ) {
                        RadioButton(selected = isSelected, onClick = null)
                        Text(choice.label, modifier = Modifier.padding(start = 8.dp))
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        },
    )
}

private const val CLOUD_MODEL = "cloudModel"
private const val LANGUAGE = "language"
private const val CLEANUP = "cleanup"
private const val CLEANUP_MODEL = "cleanupModel"
private const val ON = "on"
private const val OFF = "off"
