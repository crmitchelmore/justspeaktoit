package com.justspeaktoit.android.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class WebAuthTokenRestoreTest {
    @get:Rule
    val folder = TemporaryFolder()

    private class MemoryTokens(var token: String? = null) : WebAuthTokenStore {
        override fun load() = token

        override fun save(token: String) {
            this.token = token
        }

        override fun clear() {
            token = null
        }
    }

    private class MemoryBackup(var token: String? = null) : WebAuthTokenBackup {
        override fun read() = token

        override fun write(token: String) {
            this.token = token
        }

        override fun delete() {
            token = null
        }
    }

    private class FakeHttp(private val reply: () -> CloudKitHttpResponse) : CloudKitHttp {
        val urls = mutableListOf<String>()

        override fun send(request: CloudKitHttpRequest): CloudKitHttpResponse {
            urls += request.url
            return reply()
        }
    }

    private val config = CloudKitConfig("iCloud.com.justspeaktoit", "production", "api token")
    private val accepted = {
        CloudKitHttpResponse(
            200,
            mapOf("x-apple-cloudkit-web-auth-token" to listOf("rotated")),
            JSONObject().put("userRecordName", "_abc").toString(),
        )
    }
    private val expired = {
        val body = JSONObject().put("serverErrorCode", "AUTHENTICATION_REQUIRED").put("redirectURL", "https://idmsa.apple.com/x")
        CloudKitHttpResponse(421, emptyMap(), body.toString())
    }

    private fun service(http: FakeHttp, tokens: WebAuthTokenStore, backup: WebAuthTokenBackup, state: MemoryFile = MemoryFile()) =
        HistorySyncService(
            CloudKitWebClient(config, http, BackupMirroringTokenStore(tokens, backup), Dispatchers.Unconfined),
            null,
            AndroidHistorySyncStore(MemoryEntries(), HistorySyncStateFile(state)),
            Dispatchers.Unconfined,
            backup,
        )

    @Test
    fun testSave_mirrorsTheTokenToTheBackupAndClearDeletesIt() {
        val live = MemoryTokens()
        val backup = MemoryBackup()
        val store = BackupMirroringTokenStore(live, backup)
        store.save("token-1")
        assertEquals("token-1", live.token)
        assertEquals("token-1", backup.token)
        store.clear()
        assertNull(live.token)
        assertNull(backup.token)
    }

    @Test
    fun testFileBackup_roundTripsAndDeletes() {
        val backup = FileWebAuthTokenBackup(File(folder.root, "restore/token"))
        assertNull(backup.read())
        backup.write("a+b/c")
        backup.write("rotated")
        assertEquals("rotated", backup.read())
        backup.delete()
        assertNull(backup.read())
        backup.delete()
    }

    @Test
    fun testPrepare_restoresAValidBackedUpTokenAndEnablesSync() = runBlocking {
        val backup = MemoryBackup("restored")
        val http = FakeHttp(accepted)
        val state = MemoryFile()
        val service = service(http, MemoryTokens(), backup, state)
        service.prepare()
        assertTrue(service.status.value.signedIn)
        assertNull(service.status.value.problem)
        assertTrue(http.urls.single().endsWith("ckWebAuthToken=restored"))
        assertEquals("rotated", backup.token)
        assertTrue(state.text!!.contains("\"enabled\":true") || state.text!!.contains("\"enabled\": true"))
    }

    @Test
    fun testPrepare_expiredBackedUpTokenFallsBackToSignIn() = runBlocking {
        val backup = MemoryBackup("stale")
        val tokens = MemoryTokens()
        val service = service(FakeHttp(expired), tokens, backup)
        service.prepare()
        assertFalse(service.status.value.signedIn)
        assertNull(service.status.value.problem)
        assertNull(tokens.token)
        assertNull(backup.token)
    }

    @Test
    fun testPrepare_doesNotTouchTheBackupWhenAlreadySignedIn() = runBlocking {
        val http = FakeHttp(accepted)
        val service = service(http, MemoryTokens("live"), MemoryBackup("other"))
        service.prepare()
        assertTrue(service.status.value.signedIn)
        assertTrue(http.urls.isEmpty())
    }

    @Test
    fun testSignOut_deletesTheBackedUpToken() = runBlocking {
        val backup = MemoryBackup("restored")
        val service = service(FakeHttp(accepted), MemoryTokens(), backup)
        service.prepare()
        service.signOut()
        assertFalse(service.status.value.signedIn)
        assertNull(backup.token)
    }
}
