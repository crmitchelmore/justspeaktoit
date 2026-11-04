package com.justspeaktoit.android.history

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

enum class HistoryStatus { Completed, Failed }

/**
 * One finished dictation. Failed sessions are kept too, with any unfinished words, so they can be
 * recovered and are never mistaken for completed transcripts.
 */
data class HistoryEntry(
    val id: String,
    val createdAtMs: Long,
    val mode: String,
    val model: String?,
    val status: HistoryStatus,
    val text: String,
    val failure: String? = null,
    val cleanedUp: Boolean = false,
)

/** How long history is kept. [Off] stores nothing and deletes existing entries. */
enum class Retention(val days: Int?) {
    Off(0),
    Week(7),
    Month(30),
    Forever(null),
}

object HistoryPolicy {
    const val MAX_ENTRIES = 500
    private const val DAY_MS = 24L * 60 * 60 * 1000

    /** Newest first, within the retention window and the entry cap. */
    fun prune(entries: List<HistoryEntry>, nowMs: Long, retention: Retention): List<HistoryEntry> {
        val days = retention.days
        if (days == 0) return emptyList()
        val cutoff = if (days == null) Long.MIN_VALUE else nowMs - days * DAY_MS
        return entries.filter { it.createdAtMs >= cutoff }
            .sortedByDescending { it.createdAtMs }
            .take(MAX_ENTRIES)
    }
}

object HistoryCodec {
    private const val VERSION = 1

    fun encode(entries: List<HistoryEntry>): String {
        val items = JSONArray()
        entries.forEach { e ->
            items.put(
                JSONObject()
                    .put("id", e.id)
                    .put("createdAtMs", e.createdAtMs)
                    .put("mode", e.mode)
                    .put("model", e.model ?: JSONObject.NULL)
                    .put("status", e.status.name)
                    .put("text", e.text)
                    .put("failure", e.failure ?: JSONObject.NULL)
                    .put("cleanedUp", e.cleanedUp),
            )
        }
        return JSONObject().put("version", VERSION).put("entries", items).toString()
    }

    /** Skips entries it cannot read rather than discarding the whole history. */
    fun decode(text: String): List<HistoryEntry> {
        val items = try {
            JSONObject(text).optJSONArray("entries") ?: return emptyList()
        } catch (e: JSONException) {
            return emptyList()
        }
        return (0 until items.length()).mapNotNull { i -> items.optJSONObject(i)?.let(::entry) }
    }

    private fun entry(o: JSONObject): HistoryEntry? {
        val id = o.opt("id") as? String ?: return null
        val mode = o.opt("mode") as? String ?: return null
        val text = o.opt("text") as? String ?: return null
        val status = HistoryStatus.entries.firstOrNull { it.name == o.opt("status") } ?: return null
        val created = (o.opt("createdAtMs") as? Number)?.toLong() ?: return null
        return HistoryEntry(
            id = id,
            createdAtMs = created,
            mode = mode,
            model = o.opt("model") as? String,
            status = status,
            text = text,
            failure = o.opt("failure") as? String,
            cleanedUp = o.opt("cleanedUp") == true,
        )
    }
}

/** Durable bytes for the history; production uses an atomic file in app-private storage. */
interface HistoryFile {
    fun read(): String?

    fun write(text: String)

    fun delete()
}

/**
 * Keeps history in memory and writes it through on every change. Callers serialise access (the
 * ViewModel runs these on a single-threaded dispatcher), so no locking is needed here.
 *
 * The cache is updated before each write, so if a write fails the change stays visible and is
 * persisted by the next successful write instead of being lost.
 */
class HistoryStore(private val file: HistoryFile, private val now: () -> Long = System::currentTimeMillis) {
    private var entries: List<HistoryEntry>? = null

    /** The entries as last changed, including any not yet persisted. */
    val cached: List<HistoryEntry> get() = entries.orEmpty()

    /**
     * Reads the file and applies [retention]. It rewrites only when something was pruned, but
     * always deletes the file when retention is Off or nothing in it could be read.
     */
    fun load(retention: Retention): List<HistoryEntry> {
        val stored = file.read()
        val loaded = stored?.let(HistoryCodec::decode).orEmpty()
        val unsaved = entries.orEmpty().filter { e -> loaded.none { it.id == e.id } }
        val pruned = HistoryPolicy.prune(loaded + unsaved, now(), retention)
        val mustRewrite = pruned != loaded || (stored != null && loaded.isEmpty())
        return if (mustRewrite) save(pruned) else pruned.also { entries = it }
    }

    fun add(entry: HistoryEntry, retention: Retention): List<HistoryEntry> =
        save(HistoryPolicy.prune(listOf(entry) + current(retention), now(), retention))

    /** Replaces an existing entry (for example after cleanup); does nothing if it has gone. */
    fun replace(entry: HistoryEntry, retention: Retention): List<HistoryEntry> {
        val current = current(retention)
        if (current.none { it.id == entry.id }) return current
        return save(HistoryPolicy.prune(current.map { if (it.id == entry.id) entry else it }, now(), retention))
    }

    fun remove(id: String, retention: Retention): List<HistoryEntry> =
        save(HistoryPolicy.prune(current(retention).filterNot { it.id == id }, now(), retention))

    fun clear(): List<HistoryEntry> = save(emptyList())

    private fun current(retention: Retention) = entries ?: load(retention)

    private fun save(next: List<HistoryEntry>): List<HistoryEntry> {
        entries = next
        if (next.isEmpty()) file.delete() else file.write(HistoryCodec.encode(next))
        return next
    }
}
