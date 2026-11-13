package com.justspeaktoit.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.justspeaktoit.android.dictation.DictationViewModel
import com.justspeaktoit.android.telemetry.OptInSurface
import com.justspeaktoit.android.telemetry.Telemetry
import com.justspeaktoit.android.tips.PlayBillingTipStore
import com.justspeaktoit.android.ui.ConsentDialog
import com.justspeaktoit.android.onboarding.OnboardingGuide
import com.justspeaktoit.android.onboarding.SetupSystem
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.ui.DictationActions
import com.justspeaktoit.android.ui.DictationScreen
import com.justspeaktoit.android.ui.HistoryActions
import com.justspeaktoit.android.ui.HistoryScreen
import com.justspeaktoit.android.ui.HistoryTranscription
import com.justspeaktoit.android.ui.MicPermission
import com.justspeaktoit.android.ui.PrivacyChoices
import com.justspeaktoit.android.ui.OnboardingActions
import com.justspeaktoit.android.ui.OnboardingScreen
import com.justspeaktoit.android.ui.OnboardingStatus
import com.justspeaktoit.android.ui.AppearanceChoice
import com.justspeaktoit.android.ui.SettingsActions
import com.justspeaktoit.android.ui.SettingsScreen
import com.justspeaktoit.android.ui.theme.JustSpeakTheme
import java.io.FileNotFoundException
import java.time.LocalDate

private enum class Screen { Dictation, Settings, History, Onboarding }

class MainActivity : ComponentActivity() {
    private val viewModel: DictationViewModel by viewModels { DictationViewModel.Factory }
    private val permission = mutableStateOf(MicPermission.NotRequested)
    private val screenState = mutableStateOf(Screen.Dictation)
    private val telemetry: Telemetry get() = (application as JustSpeakApplication).telemetry
    private val privacy = mutableStateOf(PrivacyChoices())
    private val consentPending = mutableStateOf(false)
    private lateinit var tipStore: PlayBillingTipStore
    private val setupStatus = mutableStateOf(OnboardingStatus(MicPermission.NotRequested, false, false))
    private val prefs by lazy { AppPreferences(this) }
    private val appearanceState by lazy {
        mutableStateOf(AppearanceChoice(prefs.appearance, prefs.dynamicColor))
    }

    // The guide asks for the microphone without starting a recording; every other request starts one.
    private var startAfterGrant = true

    private val requestMic = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permission.value = when {
            granted -> MicPermission.Granted
            shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) -> MicPermission.Denied
            else -> MicPermission.DeniedPermanently
        }
        if (granted && startAfterGrant) {
            requestNotifications()
            viewModel.requestAutoStart()
        }
        startAfterGrant = true
    }

    // The answer does not matter: without it the recording notification is only hidden from the shade.
    private val requestNotification = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
    private var askedForNotifications = false

    private val exportConfiguration =
        registerForActivityResult(ActivityResultContracts.CreateDocument(ARCHIVE_TYPE)) { uri ->
            if (uri == null) return@registerForActivityResult
            viewModel.exportConfiguration(
                open = { contentResolver.openOutputStream(uri, "wt") },
                discard = { deleteDocument(uri) },
            )
        }

    private val importConfiguration = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult
        viewModel.inspectConfiguration { contentResolver.openInputStream(uri) }
    }

    @OptIn(ExperimentalComposeUiApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        publishShortcut()
        savedInstanceState?.getString(KEY_SCREEN)?.let { name ->
            Screen.entries.firstOrNull { it.name == name }?.let { screenState.value = it }
        }
        startAfterGrant = savedInstanceState?.getBoolean(KEY_START_AFTER_GRANT, true) ?: true
        // A recreated Activity has already acted on its launch intent.
        if (savedInstanceState == null) {
            if (shouldShowOnboarding()) screenState.value = Screen.Onboarding
            // Dictate and share intents go straight to dictation; the guide waits for the next launch.
            handleIntent(intent)
        }
        tipStore = PlayBillingTipStore(this)
        refreshPrivacy()
        val actions = DictationActions(
            onRecordTapped = ::startWithPermission,
            onStop = viewModel::stop,
            onCancel = viewModel::cancel,
            onChooseMode = viewModel::chooseMode,
            onDownloadModel = viewModel::downloadOnDeviceModel,
            onClear = viewModel::clearResult,
            onOpenSettings = ::openAppSettings,
            onShowSettings = {},
            onShowOriginal = viewModel::showOriginal,
        )
        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()
            val mic by permission
            var screen by screenState
            val privacyChoices by privacy
            val askConsent by consentPending
            val tips by tipStore.state.collectAsStateWithLifecycle()
            LaunchedEffect(screen) {
                if (screen == Screen.Settings) {
                    tipStore.connect()
                    // The keyboard may have learned corrections since the app last looked.
                    viewModel.refreshLearnedCorrections()
                    // As the Apple key pages do on open; it never blocks typing a key.
                    viewModel.refreshBalances()
                }
            }
            var appearance by appearanceState
            val dark = appearance.appearance.isDark(isSystemInDarkTheme())
            // Bar icons follow the chosen appearance, not the phone's, so they stay readable.
            DisposableEffect(dark) {
                enableEdgeToEdge(
                    statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT) { dark },
                    navigationBarStyle = SystemBarStyle.auto(LIGHT_SCRIM, DARK_SCRIM) { dark },
                )
                onDispose {}
            }
            JustSpeakTheme(dark = dark, dynamicColor = appearance.dynamicColor) {
                if (screen != Screen.Dictation) {
                    BackHandler { if (screen == Screen.Onboarding) finishOnboarding() else screen = Screen.Dictation }
                }
                // Back leaves a session running in the background rather than closing it with the screen.
                if (screen == Screen.Dictation && state.dictation.isActive) BackHandler { moveTaskToBack(true) }
                // Expose test tags as resource IDs so UiAutomator and accessibility-driven agents can find controls.
                Box(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
                    when (screen) {
                        Screen.Settings -> SettingsScreen(
                            state = state,
                            appearance = appearance,
                            actions = SettingsActions(
                                onBack = { screen = Screen.Dictation },
                                onSaveKey = viewModel::saveKey,
                                onRemoveKey = viewModel::removeKey,
                                onCheckBalance = viewModel::checkBalance,
                                onChooseModel = viewModel::chooseCloudModel,
                                onCleanupChanged = viewModel::setCleanupEnabled,
                                onKeepAudioOnCancelChanged = viewModel::setKeepAudioOnCancel,
                                onSilenceChanged = viewModel::setSilence,
                                onKeepRecordingsChanged = viewModel::setKeepRecordings,
                                onChooseCleanupModel = viewModel::chooseCleanupModel,
                                onReleaseResource = viewModel::releaseResource,
                                onReleaseEverything = viewModel::releaseEverything,
                                onChooseLanguage = viewModel::chooseLanguage,
                                onCorrectionsChanged = viewModel::setCorrections,
                                onLearnCorrectionsChanged = viewModel::setLearnCorrections,
                                onCorrectionThresholdChanged = viewModel::setCorrectionPromotionThreshold,
                                onAcceptCorrection = viewModel::acceptCorrectionCandidate,
                                onDismissCorrection = viewModel::dismissCorrectionCandidate,
                                onClearCorrectionSuggestions = viewModel::clearCorrectionCandidates,
                                onCleanupPromptChanged = viewModel::setCleanupPrompt,
                                onSaveProfile = viewModel::saveProfile,
                                onDeleteProfile = viewModel::deleteProfile,
                                onAnalyticsChanged = { optedIn ->
                                    telemetry.analytics.setOptedIn(optedIn, OptInSurface.Settings)
                                    refreshPrivacy()
                                },
                                onDiagnosticsChanged = { granted ->
                                    telemetry.crashes.setGranted(granted)
                                    refreshPrivacy()
                                },
                                onTip = { productId -> tipStore.purchase(this@MainActivity, productId) },
                                onApplyConfiguration = viewModel::applyConfiguration,
                                onRecordingSoundsChanged = viewModel::setRecordingSounds,
                                onAudioInputChanged = viewModel::setAudioInput,
                                onPreviewRecordingSound = viewModel::previewRecordingSound,
                                onRunSetup = { screen = Screen.Onboarding },
                                onAppearanceChanged = { choice ->
                                    prefs.appearance = choice.appearance
                                    prefs.dynamicColor = choice.dynamicColor
                                    appearance = choice
                                },
                                onExportConfiguration = {
                                    exportConfiguration.launch("JustSpeakToIt-config-${LocalDate.now()}.zip")
                                },
                                onImportConfiguration = { importConfiguration.launch(IMPORT_TYPES) },
                                onExportCredentialsChanged = viewModel::setExportCredentials,
                                onImportCredentialsChanged = viewModel::setImportCredentials,
                                onApplyConfigurationImport = viewModel::applyConfigurationImport,
                                onDismissConfiguration = viewModel::dismissConfigurationImport,
                            ),
                            privacy = privacyChoices,
                            tips = tips,
                        )
                        Screen.Onboarding -> OnboardingScreen(
                            state = state,
                            level = viewModel.level,
                            status = setupStatus.value.copy(mic = mic),
                            actions = onboardingActions(actions),
                        )
                        Screen.History -> HistoryScreen(
                            entries = state.history,
                            retention = state.retention,
                            saveFailed = state.historyError,
                            transcribe = HistoryTranscription(
                                sessionActive = state.dictation.isActive,
                                entryId = state.transcribingEntryId,
                            ),
                            actions = HistoryActions(
                                onBack = { screen = Screen.Dictation },
                                onRetention = viewModel::setRetention,
                                onDelete = viewModel::deleteHistoryEntry,
                                onClear = viewModel::clearHistory,
                                onTranscribe = viewModel::transcribeHistoryEntry,
                            ),
                        )
                        Screen.Dictation -> DictationScreen(
                            state = state,
                            level = viewModel.level,
                            permission = mic,
                            actions = actions.copy(
                                onShowSettings = { screen = Screen.Settings },
                                onShowHistory = { screen = Screen.History },
                                onConfirmSharedAudio = viewModel::confirmSharedAudio,
                                onDismissSharedAudio = viewModel::dismissSharedAudio,
                                onChooseProfile = viewModel::chooseProfile,
                            ),
                        )
                    }
                    // Asked once, on the main screen, never over a recording or another dialog.
                    if (askConsent && screen == Screen.Dictation && !state.dictation.isActive &&
                        state.sharedAudio == null
                    ) {
                        ConsentDialog(onDone = { analytics, diagnostics ->
                            telemetry.recordFirstRunChoices(analytics, diagnostics)
                            refreshPrivacy()
                        })
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(KEY_SCREEN, screenState.value.name)
        outState.putBoolean(KEY_START_AFTER_GRANT, startAfterGrant)
    }

    private fun handleIntent(intent: Intent?) {
        // Dictation and shared audio both happen on the main screen.
        if (intent?.component?.className == DICTATE_ENTRY || intent?.action == Intent.ACTION_SEND) {
            screenState.value = Screen.Dictation
        }
        when {
            intent == null -> Unit
            // Only the private alias may auto-start; intents to the exported Activity cannot.
            intent.component?.className == DICTATE_ENTRY -> startWithPermission()
            intent.action == Intent.ACTION_SEND -> {
                val uri = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java) ?: return
                viewModel.offerSharedAudio(uri, intent.type)
            }
        }
    }

    private fun publishShortcut() {
        val shortcut = ShortcutInfoCompat.Builder(this, "dictate")
            .setShortLabel(getString(R.string.shortcut_dictate_short))
            .setLongLabel(getString(R.string.shortcut_dictate_long))
            .setIcon(IconCompat.createWithResource(this, R.drawable.ic_shortcut_dictate))
            .setIntent(dictateIntent(this))
            .build()
        ShortcutManagerCompat.pushDynamicShortcut(this, shortcut)
    }

    override fun onStart() {
        super.onStart()
        viewModel.onEnteredApp()
        if (hasMic()) permission.value = MicPermission.Granted
        setupStatus.value = setupStatus.value.copy(keyboardEnabled = SetupSystem.isKeyboardEnabled(this))
        viewModel.refreshAvailability()
        viewModel.refreshHistory()
        viewModel.refreshLearnedCorrections()
        telemetry.analytics.appBecameActive()
    }

    override fun onDestroy() {
        tipStore.close()
        super.onDestroy()
    }

    private fun refreshPrivacy() {
        privacy.value = PrivacyChoices(telemetry.analyticsEnabled, telemetry.diagnosticsEnabled)
        consentPending.value = telemetry.needsConsentPrompt
    }

    override fun onStop() {
        if (!isChangingConfigurations) viewModel.onLeftApp()
        super.onStop()
    }

    private fun startWithPermission() {
        if (hasMic()) {
            permission.value = MicPermission.Granted
            requestNotifications()
            viewModel.requestAutoStart()
        } else {
            requestMic.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    /** The ongoing recording notification needs this from Android 13; asked once, when dictation starts. */
    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || askedForNotifications) return
        askedForNotifications = true
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) requestNotification.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun shouldShowOnboarding(): Boolean {
        val completed = prefs.hasCompletedOnboarding
        val show = OnboardingGuide.shouldShow(
            completed,
            hasChosenMode = prefs.chosenMode != null,
            micGranted = hasMic(),
        )
        // Record the decision for installs that predate the guide, so granting later never reopens it.
        if (completed == null && !show) prefs.hasCompletedOnboarding = true
        return show
    }

    private fun finishOnboarding() {
        prefs.hasCompletedOnboarding = true
        screenState.value = Screen.Dictation
    }

    private fun onboardingActions(dictation: DictationActions) = OnboardingActions(
        onRequestMic = {
            startAfterGrant = false
            requestMic.launch(Manifest.permission.RECORD_AUDIO)
        },
        onOpenAppSettings = ::openAppSettings,
        onOpenKeyboardSettings = { startActivity(SetupSystem.keyboardSettingsIntent()) },
        onAddTile = if (SetupSystem.canRequestTile) {
            {
                SetupSystem.requestTile(this) { added ->
                    setupStatus.value = setupStatus.value.copy(tileAdded = added)
                }
            }
        } else {
            null
        },
        onFinish = ::finishOnboarding,
        dictation = dictation,
    )

    private fun hasMic() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val DICTATE_ENTRY = "com.justspeaktoit.android.DictateEntry"
        private const val KEY_SCREEN = "screen"
        private const val KEY_START_AFTER_GRANT = "startAfterGrant"

        // The navigation bar scrims `enableEdgeToEdge()` uses by default.
        private val LIGHT_SCRIM = Color.argb(0xe6, 0xFF, 0xFF, 0xFF)
        private val DARK_SCRIM = Color.argb(0x80, 0x1b, 0x1b, 0x1b)

        private const val ARCHIVE_TYPE = "application/zip"

        // Some file managers label a ZIP as a generic binary or with the legacy Windows type.
        private val IMPORT_TYPES = arrayOf(ARCHIVE_TYPE, "application/x-zip-compressed", "application/octet-stream")

        fun dictateIntent(context: Context): Intent =
            Intent(Intent.ACTION_MAIN).setClassName(context, DICTATE_ENTRY)
    }

    /** Removes an export that did not finish, so a partial file is never kept as a backup. */
    private fun deleteDocument(uri: Uri) {
        try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (_: FileNotFoundException) {
            // Already gone.
        } catch (_: SecurityException) {
            // The provider does not let this app delete it; the export failure is still shown.
        } catch (_: UnsupportedOperationException) {
            // The provider does not support deleting.
        }
    }

    private fun openAppSettings() {
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)),
        )
    }
}
