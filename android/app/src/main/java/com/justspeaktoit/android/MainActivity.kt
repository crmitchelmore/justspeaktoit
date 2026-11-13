package com.justspeaktoit.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
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
import com.justspeaktoit.android.ui.DictationActions
import com.justspeaktoit.android.ui.DictationScreen
import com.justspeaktoit.android.ui.HistoryActions
import com.justspeaktoit.android.ui.HistoryScreen
import com.justspeaktoit.android.ui.HistoryTranscription
import com.justspeaktoit.android.ui.MicPermission
import com.justspeaktoit.android.ui.SettingsActions
import com.justspeaktoit.android.ui.SettingsScreen
import com.justspeaktoit.android.ui.theme.JustSpeakTheme

private enum class Screen { Dictation, Settings, History }

class MainActivity : ComponentActivity() {
    private val viewModel: DictationViewModel by viewModels { DictationViewModel.Factory }
    private val permission = mutableStateOf(MicPermission.NotRequested)
    private val screenState = mutableStateOf(Screen.Dictation)

    private val requestMic = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permission.value = when {
            granted -> MicPermission.Granted
            shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) -> MicPermission.Denied
            else -> MicPermission.DeniedPermanently
        }
        if (granted) viewModel.requestAutoStart()
    }

    @OptIn(ExperimentalComposeUiApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        publishShortcut()
        savedInstanceState?.getString(KEY_SCREEN)?.let { name ->
            Screen.entries.firstOrNull { it.name == name }?.let { screenState.value = it }
        }
        // A recreated Activity has already acted on its launch intent.
        if (savedInstanceState == null) handleIntent(intent)
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
            JustSpeakTheme {
                if (screen != Screen.Dictation) BackHandler { screen = Screen.Dictation }
                // Expose test tags as resource IDs so UiAutomator and accessibility-driven agents can find controls.
                Box(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
                    when (screen) {
                        Screen.Settings -> SettingsScreen(
                            state = state,
                            actions = SettingsActions(
                                onBack = { screen = Screen.Dictation },
                                onSaveKey = viewModel::saveKey,
                                onRemoveKey = viewModel::removeKey,
                                onChooseModel = viewModel::chooseCloudModel,
                                onCleanupChanged = viewModel::setCleanupEnabled,
                                onKeepAudioOnCancelChanged = viewModel::setKeepAudioOnCancel,
                                onChooseCleanupModel = viewModel::chooseCleanupModel,
                                onReleaseResource = viewModel::releaseResource,
                                onReleaseEverything = viewModel::releaseEverything,
                                onChooseLanguage = viewModel::chooseLanguage,
                                onCorrectionsChanged = viewModel::setCorrections,
                            ),
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
                            ),
                        )
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
        if (hasMic()) permission.value = MicPermission.Granted
        viewModel.refreshAvailability()
        viewModel.refreshHistory()
    }

    override fun onStop() {
        if (!isChangingConfigurations) viewModel.onLeftApp()
        super.onStop()
    }

    private fun startWithPermission() {
        if (hasMic()) {
            permission.value = MicPermission.Granted
            viewModel.requestAutoStart()
        } else {
            requestMic.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    private fun hasMic() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val DICTATE_ENTRY = "com.justspeaktoit.android.DictateEntry"
        private const val KEY_SCREEN = "screen"

        fun dictateIntent(context: Context): Intent =
            Intent(Intent.ACTION_MAIN).setClassName(context, DICTATE_ENTRY)
    }

    private fun openAppSettings() {
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)),
        )
    }
}
