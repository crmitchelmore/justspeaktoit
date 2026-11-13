package com.justspeaktoit.android.sync

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.core.net.toUri
import com.justspeaktoit.android.BuildConfig
import com.justspeaktoit.android.history.AtomicHistoryFile
import com.justspeaktoit.android.security.SecretStore
import kotlinx.coroutines.CoroutineDispatcher
import java.io.File

/** Keeps the CloudKit web auth token encrypted with the Keystore key that protects API keys. */
internal class KeystoreWebAuthTokenStore(private val secrets: SecretStore) : WebAuthTokenStore {
    override fun load(): String? = secrets.read(NAME)

    override fun save(token: String) = secrets.write(NAME, token)

    override fun clear() = secrets.remove(NAME)

    companion object {
        const val NAME = "cloudkit.webAuthToken"
    }
}

/** Builds History sync from this build's CloudKit configuration and the app's private files. */
internal object AndroidHistorySync {
    private const val STATE_FILE = "history-sync.json"

    fun resolution(): CloudKitResolution = CloudKitConfig.resolve(
        token = BuildConfig.CLOUDKIT_WEB_API_TOKEN,
        environment = BuildConfig.CLOUDKIT_WEB_ENVIRONMENT,
        container = CloudKitConfig.DEFAULT_CONTAINER,
    )

    fun create(
        context: Context,
        secrets: SecretStore,
        entries: SyncHistoryEntries,
        io: CoroutineDispatcher,
    ): HistorySyncService {
        val stateFile = HistorySyncStateFile(AtomicHistoryFile(File(context.filesDir, STATE_FILE)))
        return HistorySyncService.create(
            resolution = resolution(),
            http = UrlConnectionCloudKitHttp(),
            tokens = KeystoreWebAuthTokenStore(secrets),
            store = AndroidHistorySyncStore(entries, stateFile),
            io = io,
        )
    }

    /** Opens Apple's sign-in page in the user's browser; false when no browser can open it. */
    fun openInBrowser(context: Context, url: String): Boolean = try {
        val intent = Intent(Intent.ACTION_VIEW, url.toUri())
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        false
    }
}
