package com.justspeaktoit.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.justspeaktoit.android.dictation.DictationViewModel
import com.justspeaktoit.android.ui.DictationActions
import com.justspeaktoit.android.ui.DictationScreen
import com.justspeaktoit.android.ui.MicPermission
import com.justspeaktoit.android.ui.theme.JustSpeakTheme

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
        )
        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()
            val mic by permission
            JustSpeakTheme {
                DictationScreen(state = state, level = viewModel.level, permission = mic, actions = actions)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (hasMic()) permission.value = MicPermission.Granted
        viewModel.refreshAvailability()
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
