package com.justspeaktoit.android

import android.Manifest
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.justspeaktoit.android.dictation.DictationViewModel
import com.justspeaktoit.android.ui.DictationActions
import com.justspeaktoit.android.ui.DictationScreen
import com.justspeaktoit.android.ui.HistoryActions
import com.justspeaktoit.android.ui.HistoryScreen
import com.justspeaktoit.android.ui.MicPermission
import com.justspeaktoit.android.ui.SettingsActions
import com.justspeaktoit.android.ui.SettingsScreen
import com.justspeaktoit.android.ui.theme.JustSpeakTheme

private enum class Screen { Dictation, Settings, History }

class MainActivity : ComponentActivity() {
    private val viewModel: DictationViewModel by viewModels()
    private val permission = mutableStateOf(MicPermission.NotRequested)

    private val requestMic = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permission.value = when {
            granted -> MicPermission.Granted
            shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) -> MicPermission.Denied
            else -> MicPermission.DeniedPermanently
        }
        if (granted) viewModel.start()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
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
            var screen by rememberSaveable { mutableStateOf(Screen.Dictation) }
            JustSpeakTheme {
                if (screen != Screen.Dictation) BackHandler { screen = Screen.Dictation }
                when (screen) {
                    Screen.Settings -> SettingsScreen(
                        state = state,
                        actions = SettingsActions(
                            onBack = { screen = Screen.Dictation },
                            onSaveKey = viewModel::saveKey,
                            onRemoveKey = viewModel::removeKey,
                            onChooseModel = viewModel::chooseCloudModel,
                            onCleanupChanged = viewModel::setCleanupEnabled,
                        ),
                    )
                    Screen.History -> HistoryScreen(
                        entries = state.history,
                        retention = state.retention,
                        saveFailed = state.historyError,
                        actions = HistoryActions(
                            onBack = { screen = Screen.Dictation },
                            onRetention = viewModel::setRetention,
                            onDelete = viewModel::deleteHistoryEntry,
                            onClear = viewModel::clearHistory,
                        ),
                    )
                    Screen.Dictation -> DictationScreen(
                        state = state,
                        level = viewModel.level,
                        permission = mic,
                        actions = actions.copy(
                            onShowSettings = { screen = Screen.Settings },
                            onShowHistory = { screen = Screen.History },
                        ),
                    )
                }
            }
        }
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
            viewModel.start()
        } else {
            requestMic.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    private fun hasMic() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun openAppSettings() {
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)),
        )
    }
}
