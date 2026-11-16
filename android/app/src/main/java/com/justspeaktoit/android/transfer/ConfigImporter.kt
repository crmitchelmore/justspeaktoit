package com.justspeaktoit.android.transfer

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.dictation.DictationLanguages
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryPolicy
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.settings.DictationPreferences
import com.justspeaktoit.android.settings.DictationProfile
import org.json.JSONObject
import java.io.File

/** What an import changes in one category. */
data class CategoryPreview(
    val category: TransferCategory,
    val added: Int = 0,
    val updated: Int = 0,
    val unchanged: Int = 0,
    val skipped: Int = 0,
)

/** Shown before anything changes, so the user can decide whether to apply the import. */
data class ImportPreview(
    val createdAtMs: Long,
    val categories: List<CategoryPreview>,
    /** The shared English notices, as the Mac and iPhone show them. */
    val notices: List<String>,
    /** API keys the import can add or replace; only applied when the user opts in. */
    val credentials: Int,
) {
    val hasChanges: Boolean get() = credentials > 0 || categories.any { it.added + it.updated > 0 }
}

/** A value to set, so a change to null can be told apart from no change. */
internal data class Assign<T>(val value: T)

/** The settings an import changes; null fields are left as they are. */
internal data class SettingsChange(
    val keepAudioOnCancel: Boolean? = null,
    val cleanupEnabled: Boolean? = null,
    val languageId: String? = null,
    val cleanupModelId: String? = null,
    val cloudModelId: String? = null,
    val chosenMode: Assign<RecognitionMode?>? = null,
    val retention: Retention? = null,
    val cleanupPrompt: Assign<String?>? = null,
    val activeProfileId: Assign<String?>? = null,
)

/**
 * Everything an import would change, worked out against the current data without changing it.
 * [audio] maps a History entry id to its staged recording; [staged] is every staged file, deleted
 * once the plan is applied or dismissed.
 */
internal data class ImportPlan(
    val preview: ImportPreview,
    val settings: SettingsChange,
    val profiles: List<DictationProfile>?,
    val corrections: List<CorrectionRule>?,
    val history: List<HistoryEntry>,
    val audio: Map<String, File>,
    val credentials: Map<String, String>,
    val staged: Collection<File>,
)

/**
 * Plans an import as SpeakCore's `DataMigrationPlanner` does: records are merged into the existing
 * data (nothing is deleted), each kind Android has is validated and mapped, and everything else is
 * skipped with the shared notice so the user sees what was not carried over.
 */
internal object ConfigImporter {
    fun plan(
        contents: ArchiveContents,
        prefs: DictationPreferences,
        history: List<HistoryEntry>,
        savedSecrets: Set<String>,
        nowMs: Long,
    ): ImportPlan {
        val notices = contents.notices.toMutableList()
        val previews = mutableListOf<CategoryPreview>()
        val planner = Planner(contents, notices)

        val settings = planner.settings(prefs, previews)
        val profiles = planner.profiles(prefs.profiles, previews)
        val activeProfile = planner.activeProfile(contents.androidSettings, profiles ?: prefs.profiles, prefs.activeProfileId)
        val corrections = planner.corrections(prefs.corrections, previews)
        val retention = settings.retention ?: prefs.retention
        val historyPlan = planner.history(history, retention, nowMs, previews)
        val credentials = planner.credentials(savedSecrets, previews)
        planner.unused(TransferCategory.Connections, previews)
        planner.unused(TransferCategory.Models, previews)

        if (activeProfile != null) {
            val index = previews.indexOfFirst { it.category == TransferCategory.Settings }
            if (index >= 0) previews[index] = previews[index].let { it.copy(updated = it.updated + 1) }
        }
        if (settings.retention == Retention.Off && prefs.retention != Retention.Off && history.isNotEmpty()) {
            notices += "History is off in this export; applying it deletes the History on this phone."
        }
        val preview = ImportPreview(
            createdAtMs = contents.manifest.createdAtMs,
            categories = previews.sortedBy { it.category.ordinal },
            notices = notices,
            credentials = credentials.size,
        )
        return ImportPlan(
            preview = preview,
            settings = settings.copy(activeProfileId = activeProfile),
            profiles = profiles,
            corrections = corrections,
            history = historyPlan.entries,
            audio = historyPlan.audio,
            credentials = credentials,
            staged = contents.files.values,
        )
    }

    /**
     * Merges imported History into [existing]: an imported entry replaces the one with its id, keeping
     * that entry's audio if it has some; recordings attach only to entries without audio; new entries
     * are added. Applied again on the History thread when the import commits.
     */
    fun mergeHistory(
        existing: List<HistoryEntry>,
        imported: List<HistoryEntry>,
        audio: Map<String, String>,
    ): List<HistoryEntry> {
        val incoming = imported.associateBy { it.id.lowercase() }
        val merged = existing.map { entry ->
            val key = entry.id.lowercase()
            val update = incoming[key]
            val path = audio[key]
            when {
                update != null -> update.copy(id = entry.id, audioPath = entry.audioPath ?: path)
                path != null && entry.audioPath == null -> entry.copy(audioPath = path)
                else -> entry
            }
        }
        val known = existing.mapTo(mutableSetOf()) { it.id.lowercase() }
        return merged + imported.filter { it.id.lowercase() !in known }.map { it.copy(audioPath = audio[it.id.lowercase()]) }
    }

    private data class HistoryPlan(val entries: List<HistoryEntry>, val audio: Map<String, File>)

    private class Planner(private val contents: ArchiveContents, private val notices: MutableList<String>) {
        private fun records(category: TransferCategory): List<ArchiveRecord>? = contents.records[category]

        /** Records the archive's scope admits; any other is skipped with the shared notice. */
        private fun inScope(category: TransferCategory, records: List<ArchiveRecord>): List<ArchiveRecord> {
            val scope = contents.manifest.scope(category)
            return records.filter { record ->
                scope.contains(record.id, record.dateMs, record.kind).also { admitted ->
                    if (!admitted) notices += invalid(category, record.id)
                }
            }
        }

        private fun invalid(category: TransferCategory, id: String) =
            "${category.title}, $id: skipped invalid or unsupported item."

        private fun notUsed(category: TransferCategory, count: Int) {
            if (count == 0) return
            notices += if (count == 1) {
                "${category.title}: 1 item is not used on Android and was skipped."
            } else {
                "${category.title}: $count items are not used on Android and were skipped."
            }
        }

        fun unused(category: TransferCategory, previews: MutableList<CategoryPreview>) {
            val records = records(category) ?: return
            notUsed(category, records.size)
            previews += CategoryPreview(category, skipped = records.size)
        }

        fun settings(prefs: DictationPreferences, previews: MutableList<CategoryPreview>): SettingsChange {
            val category = TransferCategory.Settings
            val all = records(category) ?: return SettingsChange()
            val records = inScope(category, all)
            var change = SettingsChange()
            var updated = 0
            var unchanged = 0
            var skipped = all.size - records.size
            var unused = 0
            fun counted(same: Boolean) = if (same) unchanged++ else updated++
            fun rejected(key: String) {
                skipped++
                notices += "${category.title}, $key: not supported on Android; kept the current value."
            }
            records.forEach { record ->
                if (record.kind != RecordKinds.SETTING || record.id !in SharedSettings.keys) {
                    unused++
                    return@forEach
                }
                val value = record.value
                when (record.id) {
                    SharedSettings.KEEP_AUDIO -> (value as? Boolean)?.let {
                        counted(it == prefs.keepAudioOnCancel)
                        change = change.copy(keepAudioOnCancel = it)
                    } ?: rejected(record.id)
                    SharedSettings.CLEANUP_ENABLED -> (value as? Boolean)?.let {
                        counted(it == prefs.cleanupEnabled)
                        change = change.copy(cleanupEnabled = it)
                    } ?: rejected(record.id)
                    SharedSettings.LANGUAGE -> SharedSettings.language(value)?.let {
                        counted(it == DictationLanguages.normalized(prefs.languageId))
                        change = change.copy(languageId = it)
                    } ?: rejected(record.id)
                    SharedSettings.CLEANUP_MODEL -> SharedSettings.cleanupModel(value)?.let {
                        counted(it == CloudCatalog.cleanupModel(prefs.cleanupModelId).selectionId)
                        change = change.copy(cleanupModelId = it)
                    } ?: rejected(record.id)
                    SharedSettings.CLOUD_MODEL -> SharedSettings.cloudModel(value)?.let {
                        counted(it == CloudCatalog.transcriptionModel(prefs.cloudModelId).catalogId)
                        change = change.copy(cloudModelId = it)
                    } ?: rejected(record.id)
                }
            }
            skipped += unused
            notUsed(category, unused)
            contents.androidSettings?.let { android ->
                if (android.opt("version") != AndroidSettings.VERSION) return@let
                if (android.has(AndroidSettings.MODE)) {
                    val name = android.opt(AndroidSettings.MODE)
                    val mode = RecognitionMode.entries.firstOrNull { it.name == name }
                    if (mode != null || name == JSONObject.NULL) {
                        counted(mode == prefs.chosenMode)
                        change = change.copy(chosenMode = Assign(mode))
                    } else {
                        rejected(AndroidSettings.MODE)
                    }
                }
                if (android.has(AndroidSettings.RETENTION)) {
                    val retention = Retention.entries.firstOrNull { it.name == android.opt(AndroidSettings.RETENTION) }
                    if (retention != null) {
                        counted(retention == prefs.retention)
                        change = change.copy(retention = retention)
                    } else {
                        rejected(AndroidSettings.RETENTION)
                    }
                }
                if (android.has(AndroidSettings.PROMPT)) {
                    val prompt = android.opt(AndroidSettings.PROMPT)
                    if (prompt is String || prompt == JSONObject.NULL) {
                        val saved = (prompt as? String)?.takeIf { it.isNotBlank() }
                        counted(saved == prefs.cleanupPrompt?.takeIf { it.isNotBlank() })
                        change = change.copy(cleanupPrompt = Assign(saved))
                    } else {
                        rejected(AndroidSettings.PROMPT)
                    }
                }
            }
            previews += CategoryPreview(category, updated = updated, unchanged = unchanged, skipped = skipped)
            return change
        }

        /** The imported active profile, when it names a profile that will exist; counted with the profiles. */
        fun activeProfile(android: JSONObject?, profiles: List<DictationProfile>, current: String?): Assign<String?>? {
            if (android == null || android.opt("version") != AndroidSettings.VERSION) return null
            if (!android.has(AndroidSettings.PROFILE)) return null
            val wanted = android.opt(AndroidSettings.PROFILE)
            if (wanted == JSONObject.NULL) return Assign<String?>(null).takeIf { current != null }
            val id = wanted as? String ?: return null
            val match = profiles.firstOrNull { it.id.equals(id, ignoreCase = true) }?.id ?: return null
            return Assign<String?>(match).takeIf { match != current }
        }

        fun profiles(existing: List<DictationProfile>, previews: MutableList<CategoryPreview>): List<DictationProfile>? {
            val category = TransferCategory.Profiles
            val all = records(category) ?: return null
            val records = inScope(category, all)
            val result = existing.toMutableList()
            var added = 0
            var updated = 0
            var unchanged = 0
            var skipped = all.size - records.size
            records.forEach { record ->
                val profile = if (record.kind == RecordKinds.PROFILE) ProfileRecords.profile(record) else null
                if (profile == null) {
                    skipped++
                    notices += invalid(category, record.id)
                    return@forEach
                }
                val index = result.indexOfFirst { it.id.equals(profile.id, ignoreCase = true) }
                if (index < 0) {
                    added++
                    result += profile
                    return@forEach
                }
                // Keep the saved id's case, so the active profile still matches it.
                val incoming = profile.copy(id = result[index].id)
                if (incoming.copy(source = null) == result[index].copy(source = null)) {
                    unchanged++
                } else {
                    updated++
                    result[index] = incoming
                }
            }
            previews += CategoryPreview(category, added, updated, unchanged, skipped)
            return result.takeIf { added + updated > 0 }
        }

        fun corrections(existing: List<CorrectionRule>, previews: MutableList<CategoryPreview>): List<CorrectionRule>? {
            val category = TransferCategory.Vocabulary
            val all = records(category) ?: return null
            val records = inScope(category, all)
            val result = existing.toMutableList()
            var added = 0
            var updated = 0
            var unchanged = 0
            var unused = 0
            var skipped = all.size - records.size
            records.forEach { record ->
                if (record.kind != RecordKinds.LEXICON) {
                    unused++
                    return@forEach
                }
                val rule = LexiconRecords.rule(record)
                if (rule == null) {
                    skipped++
                    notices += invalid(category, record.id)
                    return@forEach
                }
                val index = result.indexOfFirst { it.writeAs.equals(rule.writeAs, ignoreCase = true) }
                if (index < 0) {
                    added++
                    result += rule
                    return@forEach
                }
                // Aliases from both are kept, so importing never forgets a spelling the user taught.
                val current = result[index]
                val merged = PersonalCorrections.rule(current.writeAs, current.heardAs + rule.heardAs) ?: current
                if (merged == current) {
                    unchanged++
                } else {
                    updated++
                    result[index] = merged
                }
            }
            notUsed(category, unused)
            previews += CategoryPreview(category, added, updated, unchanged, skipped + unused)
            return result.takeIf { added + updated > 0 }
        }

        fun credentials(saved: Set<String>, previews: MutableList<CategoryPreview>): Map<String, String> {
            val category = TransferCategory.Credentials
            val all = records(category) ?: return emptyMap()
            val records = inScope(category, all)
            val supported = CloudProvider.entries.mapTo(mutableSetOf()) { it.credentialId }
            val result = linkedMapOf<String, String>()
            var unused = 0
            var skipped = all.size - records.size
            records.forEach { record ->
                if (record.kind != RecordKinds.SECRET || record.id !in supported) {
                    unused++
                    return@forEach
                }
                val value = (record.value as? String)?.trim()
                if (value.isNullOrEmpty() || record.id in result) {
                    skipped++
                    notices += invalid(category, record.id)
                    return@forEach
                }
                result[record.id] = value
            }
            notUsed(category, unused)
            val replaced = result.keys.count { it in saved }
            previews += CategoryPreview(
                category,
                added = result.size - replaced,
                updated = replaced,
                skipped = skipped + unused,
            )
            return result
        }

        fun history(
            existing: List<HistoryEntry>,
            retention: Retention,
            nowMs: Long,
            previews: MutableList<CategoryPreview>,
        ): HistoryPlan {
            val historyRecords = records(TransferCategory.History)
            val audioRecords = records(TransferCategory.Recordings)
            if (historyRecords == null && audioRecords == null) return HistoryPlan(emptyList(), emptyMap())
            if (retention == Retention.Off) {
                listOfNotNull(
                    historyRecords?.let { TransferCategory.History to it.size },
                    audioRecords?.let { TransferCategory.Recordings to it.size },
                ).forEach { (category, count) ->
                    notices += "${category.title}: History is off on Android, so it was not imported."
                    previews += CategoryPreview(category, skipped = count)
                }
                return HistoryPlan(emptyList(), emptyMap())
            }
            val imported = linkedMapOf<String, HistoryEntry>()
            var historySkipped = 0
            historyRecords?.let { all ->
                val records = inScope(TransferCategory.History, all)
                historySkipped = all.size - records.size
                records.forEach { record ->
                    val entry = if (record.kind == RecordKinds.HISTORY) HistoryRecords.entry(record) else null
                    if (entry == null || entry.id in imported) {
                        historySkipped++
                        notices += invalid(TransferCategory.History, record.id)
                    } else {
                        imported[entry.id] = entry
                    }
                }
            }
            val existingIds = existing.mapTo(mutableSetOf()) { it.id.lowercase() }
            val audio = linkedMapOf<String, File>()
            val audioOnly = mutableSetOf<String>()
            var audioSkipped = 0
            audioRecords?.let { all ->
                val records = inScope(TransferCategory.Recordings, all)
                audioSkipped = all.size - records.size
                records.forEach { record ->
                    val file = record.file?.let { contents.files[it] }
                    val entry = if (record.kind == RecordKinds.AUDIO) HistoryRecords.entry(record) else null
                    when {
                        entry == null || file == null || entry.id in audio -> {
                            audioSkipped++
                            notices += invalid(TransferCategory.Recordings, record.id)
                        }
                        file.extension.lowercase() != "wav" -> {
                            audioSkipped++
                            notices += "${TransferCategory.Recordings.title}, ${record.id}: " +
                                "only WAV recordings can be imported on Android; skipped."
                        }
                        else -> {
                            audio[entry.id] = file
                            if (entry.id !in imported && entry.id !in existingIds) {
                                // A recording without its text becomes a kept recording, ready to transcribe.
                                imported[entry.id] = entry.copy(status = HistoryStatus.Cancelled, text = "", failure = null)
                                audioOnly += entry.id
                            }
                        }
                    }
                }
            }
            val placeholders = audio.mapValues { (id, _) -> "import:$id" }
            val kept = HistoryPolicy.prune(mergeHistory(existing, imported.values.toList(), placeholders), nowMs, retention)
                .associateBy { it.id.lowercase() }
            val attached = audio.keys.filterTo(mutableSetOf()) { id -> kept[id]?.audioPath == placeholders[id] }
            val before = existing.associateBy { it.id.lowercase() }
            var added = 0
            var updated = 0
            var unchanged = 0
            var pruned = 0
            imported.values.filter { it.id !in audioOnly }.forEach { entry ->
                val previous = before[entry.id]
                val now = kept[entry.id]
                when {
                    now == null -> pruned++
                    previous == null -> added++
                    // Recordings are counted on their own, so a newly attached one is not a text change.
                    now.copy(audioPath = previous.audioPath) == previous -> unchanged++
                    else -> updated++
                }
            }
            if (pruned > 0) {
                notices += "${TransferCategory.History.title}: $pruned entries are outside this phone's History " +
                    "setting or its ${HistoryPolicy.MAX_ENTRIES}-entry limit and were skipped."
            }
            // An entry that already has its recording keeps it, so importing the same archive twice changes nothing.
            val present = audio.keys.count { id -> id !in attached && kept[id]?.audioPath != null }
            val unattached = audio.size - attached.size - present
            if (unattached > 0) {
                notices += "${TransferCategory.Recordings.title}: $unattached recordings belong to History entries " +
                    "outside this phone's History setting and were skipped."
            }
            historyRecords?.let {
                previews += CategoryPreview(
                    TransferCategory.History,
                    added = added,
                    updated = updated,
                    unchanged = unchanged,
                    skipped = historySkipped + pruned,
                )
            }
            audioRecords?.let {
                previews += CategoryPreview(
                    TransferCategory.Recordings,
                    added = attached.size,
                    unchanged = present,
                    skipped = audioSkipped + unattached,
                )
            }
            return HistoryPlan(imported.values.filter { it.id in kept }, audio.filterKeys { it in attached })
        }
    }
}
