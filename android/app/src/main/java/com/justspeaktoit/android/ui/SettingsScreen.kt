package com.justspeaktoit.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.justspeaktoit.android.R
import com.justspeaktoit.android.diagnostics.AndroidIssueEnvironment
import com.justspeaktoit.android.diagnostics.IssueFacts
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CleanupModelPicker
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.dictation.SilenceSettings
import com.justspeaktoit.android.settings.ApiKeyStatusFilter
import com.justspeaktoit.android.settings.AppAppearance
import com.justspeaktoit.android.settings.DictationProfile
import com.justspeaktoit.android.settings.RecordingSoundSettings
import com.justspeaktoit.android.settings.SettingsSearchEntry
import com.justspeaktoit.android.settings.SettingsSearchIndex
import com.justspeaktoit.android.settings.SettingsSearchRecents
import com.justspeaktoit.android.settings.SettingsSearchResult
import com.justspeaktoit.android.tips.TipJarUiState
import com.justspeaktoit.android.ui.theme.supportsDynamicColor

class SettingsActions(
    val onBack: () -> Unit,
    val onSaveKey: (CloudProvider, String) -> Unit,
    val onRemoveKey: (CloudProvider) -> Unit,
    val onChooseModel: (CloudModel) -> Unit,
    val onCleanupChanged: (Boolean) -> Unit,
    val onKeepAudioOnCancelChanged: (Boolean) -> Unit,
    val onChooseCleanupModel: (CleanupModel) -> Unit,
    val onReleaseResource: (String) -> Unit = {},
    val onReleaseEverything: () -> Unit = {},
    val onChooseLanguage: (String) -> Unit = {},
    val onCorrectionsChanged: (List<CorrectionRule>) -> Unit = {},
    val onLearnCorrectionsChanged: (Boolean) -> Unit = {},
    val onCorrectionThresholdChanged: (Int) -> Unit = {},
    val onAcceptCorrection: (String) -> Unit = {},
    val onDismissCorrection: (String) -> Unit = {},
    val onClearCorrectionSuggestions: () -> Unit = {},
    val onCleanupPromptChanged: (String) -> Unit = {},
    val onSaveProfile: (DictationProfile) -> Unit = {},
    val onDeleteProfile: (String) -> Unit = {},
    val onAnalyticsChanged: (Boolean) -> Unit = {},
    val onDiagnosticsChanged: (Boolean) -> Unit = {},
    val onTip: (String) -> Unit = {},
    /** Applies validated raw-configuration changes all or none; false when they cannot apply now. */
    val onApplyConfiguration: (Map<String, Any?>) -> Boolean = { false },
    val onRecordingSoundsChanged: (RecordingSoundSettings) -> Unit = {},
    val onPreviewRecordingSound: () -> Unit = {},
    val onSilenceChanged: (SilenceSettings) -> Unit = {},
    val onRunSetup: () -> Unit = {},
    val onAppearanceChanged: (AppearanceChoice) -> Unit = {},
)

/** The app-wide theme choice: light, dark or the phone's, and wallpaper colours where supported. */
data class AppearanceChoice(val appearance: AppAppearance = AppAppearance.System, val dynamicColor: Boolean = false)

const val PRIVACY_POLICY_URL = "https://justspeaktoit.com/privacy"

/** Where a search result scrolls to on this screen. */
private fun anchorFor(entry: SettingsSearchEntry): String = when {
    entry.id.startsWith(SettingsSearchIndex.MODEL_PREFIX) -> "android.cloudModel"
    else -> entry.id
}

@Composable
fun SettingsScreen(
    state: DictationUiState,
    actions: SettingsActions,
    privacy: PrivacyChoices = PrivacyChoices(),
    appearance: AppearanceChoice = AppearanceChoice(),
    tips: TipJarUiState = TipJarUiState(),
) {
    val context = LocalContext.current
    val searchIndex = remember {
        context.assets.open("settings_search.json").bufferedReader().use {
            SettingsSearchIndex.fromCatalogueJson(it.readText())
        }
    }
    val scrollState = rememberScrollState()
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    var query by rememberSaveable { mutableStateOf("") }
    var keyFilter by rememberSaveable { mutableStateOf(ApiKeyStatusFilter.All) }
    var recents by remember { mutableStateOf(emptyList<String>()) }
    var highlighted by remember { mutableStateOf<String?>(null) }
    val anchors = remember { mutableStateMapOf<String, Int>() }
    val highlightColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.16f)
    LaunchedEffect(highlighted) {
        if (highlighted != null) {
            delay(2_500)
            highlighted = null
        }
    }
    // Records where each search destination sits and tints it briefly when a result opens it.
    fun anchor(id: String): Modifier = Modifier
        .onGloballyPositioned { anchors[id] = it.positionInParent().y.toInt() }
        .background(if (highlighted == id) highlightColor else Color.Transparent, RoundedCornerShape(8.dp))
    fun open(entry: SettingsSearchEntry) {
        recents = SettingsSearchRecents.recording(entry.id, recents)
        query = ""
        focusManager.clearFocus()
        val target = anchorFor(entry)
        // A key hidden by the status filter must still be reachable from search.
        if (target.startsWith(SettingsSearchIndex.KEY_PREFIX)) keyFilter = ApiKeyStatusFilter.All
        highlighted = target
        scope.launch { anchors[target]?.let { scrollState.animateScrollTo(it) } }
    }

    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(scrollState)
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = actions.onBack, modifier = Modifier.testTag(AutomationIds.SETTINGS_BACK)) {
                    Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.action_back))
                }
                Text(
                    stringResource(R.string.settings_title),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            SettingsSearchField(query, onQueryChange = { query = it })
            if (query.isNotBlank()) {
                SettingsSearchResults(
                    // Only destinations this screen renders; the catalogue can run ahead of the UI.
                    results = searchIndex.search(query, limit = 20).filter { anchorFor(it.entry) in anchors },
                    completions = searchIndex.completions(query),
                    onComplete = { query = it },
                    onOpen = ::open,
                )
                return@Column
            }
            val recentEntries = recents.mapNotNull(searchIndex::entry).filter { anchorFor(it) in anchors }
            if (recentEntries.isNotEmpty()) {
                Text(
                    stringResource(R.string.settings_search_recent),
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.semantics { heading() },
                )
                recentEntries.forEach { entry -> SearchResultRow(SettingsSearchResult(entry, 0, null), ::open) }
                HorizontalDivider()
            }

            SectionTitle(R.string.settings_language_title, anchor("android.language"))
            LanguageRow(state.languageId, actions.onChooseLanguage)

            HorizontalDivider()
            SectionTitle(R.string.settings_cloud_model_title, anchor("android.cloudModel"))
            CloudCatalog.transcriptionModels.forEach { model ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .selectable(
                            selected = model == state.cloudModel,
                            role = Role.RadioButton,
                            onClick = { actions.onChooseModel(model) },
                        ),
                ) {
                    RadioButton(selected = model == state.cloudModel, onClick = null)
                    Text(model.displayName, modifier = Modifier.padding(start = 8.dp))
                }
            }

            HorizontalDivider()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = anchor("android.cleanup")
                    .fillMaxWidth()
                    .toggleable(
                        value = state.cleanupEnabled,
                        role = Role.Switch,
                        onValueChange = actions.onCleanupChanged,
                    ),
            ) {
                Text(
                    stringResource(R.string.settings_cleanup_title),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = state.cleanupEnabled, onCheckedChange = null)
            }
            Text(stringResource(R.string.settings_cleanup_note), style = MaterialTheme.typography.bodyMedium)
            CleanupModelRow(state, actions)
            if (state.cleanupEnabled && state.cleanupModel.provider !in state.savedKeys) {
                Text(
                    stringResource(R.string.settings_cleanup_needs_key, state.cleanupModel.provider.displayName),
                    color = MaterialTheme.colorScheme.error,
                )
            }
            CleanupPromptField(
                stringResource(R.string.settings_cleanup_prompt_title),
                state.cleanupPrompt,
                actions.onCleanupPromptChanged,
                anchor("android.cleanupPrompt"),
            )

            HorizontalDivider()
            SectionTitle(R.string.settings_profiles_title, anchor("android.profiles"))
            ProfilesEditor(
                profiles = state.profiles,
                activeId = state.profile?.id,
                savedKeys = state.savedKeys,
                onSave = actions.onSaveProfile,
                onDelete = actions.onDeleteProfile,
            )

            HorizontalDivider()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = anchor("android.keepAudio")
                    .fillMaxWidth()
                    .toggleable(
                        value = state.keepAudioOnCancel,
                        role = Role.Switch,
                        onValueChange = actions.onKeepAudioOnCancelChanged,
                    ),
            ) {
                Text(
                    stringResource(R.string.settings_keep_audio_title),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = state.keepAudioOnCancel, onCheckedChange = null)
            }
            Text(stringResource(R.string.settings_keep_audio_note), style = MaterialTheme.typography.bodyMedium)

            HorizontalDivider()
            RecordingSoundsSection(
                state.recordingSounds,
                onChange = actions.onRecordingSoundsChanged,
                onPreview = actions.onPreviewRecordingSound,
                modifier = anchor("android.recordingSounds"),
            )

            HorizontalDivider()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = anchor("android.silenceDetection")
                    .fillMaxWidth()
                    .testTag(AutomationIds.SETTINGS_SILENCE)
                    .toggleable(
                        value = state.silence.enabled,
                        role = Role.Switch,
                        onValueChange = { actions.onSilenceChanged(state.silence.copy(enabled = it)) },
                    ),
            ) {
                Text(
                    stringResource(R.string.settings_silence_title),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = state.silence.enabled, onCheckedChange = null)
            }
            Text(stringResource(R.string.settings_silence_note), style = MaterialTheme.typography.bodyMedium)
            if (state.silence.enabled) SilenceSliders(state.silence, actions.onSilenceChanged)

            HorizontalDivider()
            SectionTitle(R.string.settings_corrections_title, anchor("android.personalCorrections"))
            CorrectionsEditor(state.corrections, actions.onCorrectionsChanged)

            HorizontalDivider()
            SectionTitle(R.string.settings_learned_corrections_title, anchor("android.learnedCorrections"))
            LearnedCorrections(
                enabled = state.learnCorrections,
                threshold = state.correctionPromotionThreshold,
                candidates = state.correctionCandidates,
                actions = actions,
            )

            HorizontalDivider()
            SectionTitle(R.string.settings_appearance_title, anchor("android.appearance"))
            AppearanceSection(appearance, actions.onAppearanceChanged)

            HorizontalDivider()
            SectionTitle(R.string.settings_raw_config_title, anchor("general.rawConfiguration"))
            RawConfigurationEditor(state, actions.onApplyConfiguration)

            HorizontalDivider()
            SectionTitle(R.string.settings_resources_title, anchor("android.resourcesInUse"))
            ResourcesInUse(state.resourcesInUse, actions)

            HorizontalDivider()
            SectionTitle(R.string.settings_keys_title, anchor("android.apiKeys"))
            Text(stringResource(R.string.settings_keys_note), style = MaterialTheme.typography.bodyMedium)
            if (state.keyStoreError) {
                Text(stringResource(R.string.settings_key_error), color = MaterialTheme.colorScheme.error)
            }
            KeyFilterPicker(keyFilter, onFilter = { keyFilter = it })
            val visibleProviders = CloudCatalog.providers.filter {
                keyFilter.matches(saved = it in state.savedKeys, hasError = it in state.keyErrors)
            }
            if (visibleProviders.isEmpty()) {
                Text(
                    stringResource(keyFilter.emptyMessage),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            visibleProviders.forEach { provider ->
                KeyRow(
                    provider,
                    saved = provider in state.savedKeys,
                    failed = provider in state.keyErrors,
                    actions,
                    anchor("${SettingsSearchIndex.KEY_PREFIX}${provider.id}"),
                )
            }

            HorizontalDivider()
            Text(
                stringResource(R.string.settings_privacy_title),
                style = MaterialTheme.typography.titleLarge,
                modifier = anchor("android.privacy").semantics { heading() },
            )
            ConsentSwitchRow(
                R.string.settings_analytics_title,
                privacy.analytics,
                actions.onAnalyticsChanged,
                anchor("android.analytics").testTag(AutomationIds.SETTINGS_ANALYTICS),
            )
            Text(stringResource(R.string.settings_analytics_note), style = MaterialTheme.typography.bodyMedium)
            ConsentSwitchRow(
                R.string.settings_diagnostics_title,
                privacy.diagnostics,
                actions.onDiagnosticsChanged,
                anchor("android.diagnostics").testTag(AutomationIds.SETTINGS_DIAGNOSTICS),
            )
            Text(stringResource(R.string.settings_diagnostics_note), style = MaterialTheme.typography.bodyMedium)

            HorizontalDivider()
            SectionTitle(R.string.settings_support_title, anchor("android.tipJar"))
            TipJarSection(tips, actions.onTip)

            HorizontalDivider()
            SectionTitle(R.string.settings_setup_title, anchor("android.setupGuide"))
            Text(stringResource(R.string.settings_setup_note), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(
                onClick = actions.onRunSetup,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_RUN_SETUP),
            ) { Text(stringResource(R.string.settings_setup_run)) }

            HorizontalDivider()
            val uriHandler = LocalUriHandler.current
            // Google Play's User Data policy requires the privacy policy inside the app as well as on the listing.
            TextButton(
                onClick = { uriHandler.openUri(PRIVACY_POLICY_URL) },
                modifier = anchor("android.privacyPolicy").testTag(AutomationIds.SETTINGS_PRIVACY_POLICY),
            ) {
                Text(stringResource(R.string.privacy_policy_link))
            }
            var reporting by rememberSaveable { mutableStateOf(false) }
            TextButton(
                onClick = { reporting = true },
                modifier = anchor("android.reportIssue").testTag(AutomationIds.SETTINGS_REPORT_ISSUE),
            ) {
                Text(stringResource(R.string.settings_report_issue))
            }
            if (reporting) {
                val facts = remember { IssueFacts.forSettings(AndroidIssueEnvironment.current(context)) }
                IssueReportDialog(facts) { reporting = false }
            }
        }
    }
}

@Composable
private fun CleanupModelRow(state: DictationUiState, actions: SettingsActions) {
    var picking by remember { mutableStateOf(false) }
    val title = stringResource(R.string.settings_cleanup_model)
    val label = CleanupModelPicker.selectionLabel(state.cleanupModel)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.SETTINGS_CLEANUP_MODEL)
            .clickable(role = Role.Button) { picking = true }
            .semantics(mergeDescendants = true) { contentDescription = "$title, $label" }
            .padding(vertical = 8.dp),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.weight(1f),
        )
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.primary,
        )
    }
    if (picking) {
        CleanupModelPickerDialog(
            selected = state.cleanupModel,
            savedKeys = state.savedKeys,
            onChoose = {
                actions.onChooseCleanupModel(it)
                picking = false
            },
            onDismiss = { picking = false },
        )
    }
}

/** The user's base cleanup prompt; every edit is saved, and empty means the built-in prompt. */
@Composable
private fun CleanupPromptField(title: String, saved: String?, onChange: (String) -> Unit, modifier: Modifier) {
    var text by rememberSaveable { mutableStateOf(saved.orEmpty()) }
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        OutlinedTextField(
            value = text,
            onValueChange = {
                text = it
                onChange(it)
            },
            label = { Text(title) },
            supportingText = { Text(stringResource(R.string.settings_cleanup_prompt_note)) },
            minLines = 3,
            modifier = Modifier.fillMaxWidth().testTag(AutomationIds.SETTINGS_CLEANUP_PROMPT),
        )
        if (text.isNotBlank()) {
            TextButton(
                onClick = {
                    text = ""
                    onChange("")
                },
                modifier = Modifier.testTag(AutomationIds.SETTINGS_CLEANUP_PROMPT_RESET),
            ) {
                Text(stringResource(R.string.settings_cleanup_prompt_reset))
            }
        }
    }
}

@Composable
private fun AppearanceSection(choice: AppearanceChoice, onChange: (AppearanceChoice) -> Unit) {
    AppAppearance.entries.forEach { option ->
        val selected = option == choice.appearance
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.appearanceOption(option.rawValue))
                .selectable(
                    selected = selected,
                    role = Role.RadioButton,
                    onClick = { onChange(choice.copy(appearance = option)) },
                ),
        ) {
            RadioButton(selected = selected, onClick = null)
            Text(stringResource(option.label), modifier = Modifier.padding(start = 8.dp))
        }
    }
    if (!supportsDynamicColor) return
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(AutomationIds.SETTINGS_DYNAMIC_COLOR)
            .toggleable(
                value = choice.dynamicColor,
                role = Role.Switch,
                onValueChange = { onChange(choice.copy(dynamicColor = it)) },
            ),
    ) {
        Text(
            stringResource(R.string.settings_dynamic_color_label),
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.weight(1f),
        )
        Switch(checked = choice.dynamicColor, onCheckedChange = null)
    }
    Text(stringResource(R.string.settings_dynamic_color_note), style = MaterialTheme.typography.bodyMedium)
}

private val AppAppearance.label: Int
    @StringRes get() = when (this) {
        AppAppearance.System -> R.string.settings_appearance_system
        AppAppearance.Light -> R.string.settings_appearance_light
        AppAppearance.Dark -> R.string.settings_appearance_dark
    }

@Composable
private fun SectionTitle(@StringRes title: Int, modifier: Modifier = Modifier) {
    Text(
        stringResource(title),
        style = MaterialTheme.typography.titleMedium,
        modifier = modifier.semantics { heading() },
    )
}
