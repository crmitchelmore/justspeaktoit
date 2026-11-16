package com.justspeaktoit.android.local

import android.app.ActivityManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import kotlinx.coroutines.CoroutineDispatcher
import org.json.JSONException
import java.io.File
import java.io.IOException

/** The production wiring for downloaded Whisper models. */
object AndroidLocalModels {
    fun setup(context: Context, io: CoroutineDispatcher): LocalModelSetup = LocalModelSetup(
        catalog = loadCatalog(context),
        store = WhisperModelStore(File(context.filesDir, "models/whisper")),
        downloader = ModelDownloader(),
        totalMemoryBytes = totalMemory(context),
        network = ConnectivityNetworkGate(context),
        transcriber = WhisperCppTranscriber(io),
    )

    /** A missing or unreadable asset offers no models rather than stopping the app. */
    private fun loadCatalog(context: Context): List<WhisperModel> = try {
        context.assets.open(WhisperCatalog.ASSET).bufferedReader().use { WhisperCatalog.parse(it.readText()) }
    } catch (e: IOException) {
        emptyList()
    } catch (e: JSONException) {
        emptyList()
    } catch (e: IllegalArgumentException) {
        emptyList()
    }

    private fun totalMemory(context: Context): Long {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return 0L
        return ActivityManager.MemoryInfo().also(manager::getMemoryInfo).totalMem
    }
}

/** Wi-Fi or another unmetered network, or any connection once the user allows mobile data. */
private class ConnectivityNetworkGate(context: Context) : NetworkGate {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)

    override fun canDownload(allowMobileData: Boolean): Boolean {
        val manager = connectivity ?: return false
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        return allowMobileData || capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }
}
