package com.justspeaktoit.android.output

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build

object TranscriptOutput {
    /**
     * Copies [text] and returns whether the app should confirm it. Android 13+ shows its own
     * clipboard confirmation, so the app stays quiet there to avoid a duplicate message.
     */
    fun copy(context: Context, text: String): Boolean {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return false
        clipboard.setPrimaryClip(ClipData.newPlainText("Transcript", text))
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
    }

    fun share(context: Context, text: String, chooserTitle: String) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        context.startActivity(Intent.createChooser(send, chooserTitle))
    }
}
