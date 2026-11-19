package com.justspeaktoit.android.onboarding

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import com.justspeaktoit.android.R
import com.justspeaktoit.android.ime.DictationKeyboardService
import com.justspeaktoit.android.surfaces.DictateTileService

/** System state and screens the setup guide points at. */
object SetupSystem {
    /** Whether the user has turned on the dictation keyboard in the system's keyboard list. */
    fun isKeyboardEnabled(context: Context): Boolean {
        val keyboard = ComponentName(context, DictationKeyboardService::class.java)
        val manager = context.getSystemService(InputMethodManager::class.java) ?: return false
        return manager.enabledInputMethodList.any { it.component == keyboard }
    }

    fun keyboardSettingsIntent(): Intent =
        Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** Android 13 can offer the tile in a system dialog; earlier versions need the edit panel. */
    val canRequestTile: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

    /** Asks the system to add the Dictate tile; [onResult] receives true once it is in Quick Settings. */
    fun requestTile(context: Context, onResult: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return onResult(false)
        val manager = context.getSystemService(StatusBarManager::class.java) ?: return onResult(false)
        manager.requestAddTileService(
            ComponentName(context, DictateTileService::class.java),
            context.getString(R.string.tile_label),
            Icon.createWithResource(context, R.drawable.ic_mic),
            context.mainExecutor,
        ) { result ->
            onResult(
                result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                    result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED,
            )
        }
    }
}
