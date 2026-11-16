package com.justspeaktoit.android.sync

import com.justspeaktoit.android.history.HistoryFile
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * What the server has acknowledged for one local entry, as DesktopCloudSyncState.HistoryEntryState.
 * [acknowledged] and [observed] are fingerprints; the entry is pending while they differ.
 */
data class HistoryEntrySyncState(
    val acknowledged: String?,
    val observed: String,
    val updatedAtMs: Long,
    val deletedElsewhere: Boolean = false,
)

/**
 * A local deletion (desktop `DesktopHistoryDeletionLedger.Intent`). An intent with an [account]
 * is sent to that account's iCloud while [cloudPending]; every intent stops a remote copy coming back.
 */
data class HistoryDeletionIntent(
    val id: String,
    val revision: String,
    val account: String?,
    val cloudPending: Boolean,
)

data class HistorySyncState(
    /** Whether the user has signed in and not signed out. */
    val enabled: Boolean = false,
    /** The iCloud user record this device's state belongs to. */
    val account: String? = null,
    val cursor: String? = null,
    val history: Map<String, HistoryEntrySyncState> = emptyMap(),
    val deletions: Map<String, HistoryDeletionIntent> = emptyMap(),
    val lastSuccessfulSyncMs: Long? = null,
) {
    fun forgetAccountData(): HistorySyncState = copy(cursor = null, history = emptyMap(), lastSuccessfulSyncMs = null)
}

object HistorySyncStateCodec {
    private const val VERSION = 1

    fun encode(state: HistorySyncState): String {
        val history = JSONObject()
        state.history.toSortedMap().forEach { (id, s) ->
            history.put(
                id,
                JSONObject()
                    .put("acknowledged", s.acknowledged ?: JSONObject.NULL)
                    .put("observed", s.observed)
                    .put("updatedAtMs", s.updatedAtMs)
                    .put("deletedElsewhere", s.deletedElsewhere),
            )
        }
        val deletions = JSONArray()
        state.deletions.toSortedMap().values.forEach { d ->
            deletions.put(
                JSONObject()
                    .put("id", d.id)
                    .put("revision", d.revision)
                    .put("account", d.account ?: JSONObject.NULL)
                    .put("cloudPending", d.cloudPending),
            )
        }
        return JSONObject()
            .put("version", VERSION)
            .put("enabled", state.enabled)
            .put("account", state.account ?: JSONObject.NULL)
            .put("cursor", state.cursor ?: JSONObject.NULL)
            .put("history", history)
            .put("deletions", deletions)
            .put("lastSuccessfulSyncMs", state.lastSuccessfulSyncMs ?: JSONObject.NULL)
            .toString()
    }

    /** Null when the text is unreadable or from another version, so the caller can start again. */
    fun decode(text: String): HistorySyncState? {
        val root = try {
            JSONObject(text)
        } catch (e: JSONException) {
            return null
        }
        if (root.opt("version") != VERSION) return null
        val history = mutableMapOf<String, HistoryEntrySyncState>()
        root.optJSONObject("history")?.let { items ->
            items.keys().forEach { id ->
                val o = items.optJSONObject(id) ?: return@forEach
                val observed = o.opt("observed") as? String ?: return@forEach
                val updatedAt = (o.opt("updatedAtMs") as? Number)?.toLong() ?: return@forEach
                history[id] = HistoryEntrySyncState(
                    acknowledged = o.opt("acknowledged") as? String,
                    observed = observed,
                    updatedAtMs = updatedAt,
                    deletedElsewhere = o.opt("deletedElsewhere") == true,
                )
            }
        }
        val deletions = mutableMapOf<String, HistoryDeletionIntent>()
        root.optJSONArray("deletions")?.let { items ->
            for (i in 0 until items.length()) {
                val o = items.optJSONObject(i) ?: continue
                val id = o.opt("id") as? String ?: continue
                val revision = o.opt("revision") as? String ?: continue
                deletions[id] = HistoryDeletionIntent(id, revision, o.opt("account") as? String, o.opt("cloudPending") == true)
            }
        }
        return HistorySyncState(
            enabled = root.opt("enabled") == true,
            account = root.opt("account") as? String,
            cursor = root.opt("cursor") as? String,
            history = history,
            deletions = deletions,
            lastSuccessfulSyncMs = (root.opt("lastSuccessfulSyncMs") as? Number)?.toLong(),
        )
    }
}

/** Reads and writes [HistorySyncState] through [file]; callers serialise access. */
class HistorySyncStateFile(private val file: HistoryFile) {
    fun load(): HistorySyncState = file.read()?.let(HistorySyncStateCodec::decode) ?: HistorySyncState()

    fun save(state: HistorySyncState) = file.write(HistorySyncStateCodec.encode(state))
}
