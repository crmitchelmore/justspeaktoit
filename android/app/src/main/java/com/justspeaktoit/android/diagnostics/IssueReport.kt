package com.justspeaktoit.android.diagnostics

import java.net.URLEncoder

/**
 * The Android counterpart of SpeakCore's `IssueDiagnosticReport` (issue #1633): one frozen,
 * allowlisted report with the same JSON schema, issue body and GitHub draft link. It never reads
 * settings, keys, transcripts, audio, raw errors, logs, persistent IDs or absolute times; callers
 * pass only the enum facts in [IssueFacts], and the user previews these exact bytes before sharing.
 */
class IssueReport private constructor(val title: String, val body: String, val json: String, val issueUrl: String?) {
    enum class Section(val wire: String) {
        Environment("environment"),
        Models("models"),
        Options("options"),
        Failures("failures"),
        Timeline("timeline"),
    }

    companion object {
        const val ATTACHMENT_FILENAME = "justspeaktoit-diagnostics.json"
        const val TITLE = "Request issue — privacy-safe diagnostics"
        private const val NEW_ISSUE_URL = "https://github.com/crmitchelmore/justspeaktoit/issues/new"
        private const val MAX_URL_LENGTH = 7_500
        private const val MAX_JSON_BYTES = 16 * 1_024
        private const val MAX_MODELS = 8
        private const val MAX_FAILURES = 8
        private const val UNAVAILABLE_JSON = """{"schemaVersion":1,"reportState":"serializationUnavailable"}"""

        /** Builds the report; [omitted] sections are removed, and removing every section drops the context too. */
        fun build(facts: IssueFacts, omitted: Set<Section> = emptySet()): IssueReport {
            val encoded = IssueJson.write(payload(facts, omitted))
            val json = if (encoded.toByteArray(Charsets.UTF_8).size <= MAX_JSON_BYTES) encoded else UNAVAILABLE_JSON
            val body = body(json)
            val url = "$NEW_ISSUE_URL?title=${encode(TITLE)}&body=${encode(body)}&labels=bug"
            return IssueReport(TITLE, body, json, url.takeIf { it.length <= MAX_URL_LENGTH })
        }

        private fun payload(facts: IssueFacts, omitted: Set<Section>): Map<String, Any?> {
            val removeAll = omitted.containsAll(Section.entries)
            val noModels = Section.Models in omitted
            val noFailures = Section.Failures in omitted
            val recorded = facts.recordedModels
            val failures = facts.failures
            return mapOf(
                "schemaVersion" to 1,
                "contextState" to when {
                    removeAll -> "userRemoved"
                    facts.context != null -> "admission"
                    else -> "missingLegacyContext"
                },
                "context" to facts.context?.takeUnless { removeAll }
                    ?.toJson(includeModels = !noModels),
                "recordedModels" to if (noModels) null else recorded.take(MAX_MODELS).map { it.toJson() },
                "environment" to if (Section.Environment in omitted) null else facts.environment.toJson(),
                "failures" to if (noFailures) null else failures.take(MAX_FAILURES).map { it.toJson() },
                // Android History keeps no stage timings, so the timeline is always empty.
                "timeline" to if (Section.Timeline in omitted) null else emptyList<Any>(),
                "omittedSections" to Section.entries.filter { it in omitted }.map { it.wire },
                "omissionReason" to if (omitted.isEmpty()) null else "userRemoved",
                "truncated" to mapOf(
                    "recordedModels" to if (noModels) 0 else maxOf(0, recorded.size - MAX_MODELS),
                    "failures" to if (noFailures) 0 else maxOf(0, failures.size - MAX_FAILURES),
                    "timeline" to 0,
                ),
            )
        }

        private fun body(json: String): String = """
            |## Description
            |Describe the problem (for example wrong text, a slow request or the wrong model) and reproduction steps
            |here after reviewing these details.
            |
            |## Request diagnostics
            |These details contain only recorded allowlisted fields. Missing or invalid values are omitted.
            |Legacy records do not establish request-time effective configuration.
            |Admission and recorded model IDs are not verified handoffs.
            |An observed handoff means a client call, not remote acceptance or its wrapped transport.
            |Failure observations may overlap; they are not a request count.
            |No transcript, audio, raw errors, logs, persistent IDs or absolute timestamps are included.
            |
            |```json
            |$json
            |```
            |
            |Attach $ATTACHMENT_FILENAME manually if desired. Opening this draft does not upload the JSON attachment.
            |Add your own reproduction steps after reviewing what you want to share.
        """.trimMargin()

        private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
    }
}

/** Writes the payload as sorted, pretty-printed JSON. Null values are left out, as Swift's encoder does. */
internal object IssueJson {
    fun write(value: Any?): String = StringBuilder().also { append(it, value, 0) }.toString()

    private fun append(out: StringBuilder, value: Any?, depth: Int) {
        when (value) {
            is Map<*, *> -> {
                val entries = value.entries.filter { it.value != null }.sortedBy { it.key.toString() }
                container(out, '{', '}', entries, depth) { entry ->
                    string(out, entry.key.toString())
                    out.append(" : ")
                    append(out, entry.value, depth + 1)
                }
            }
            is List<*> -> container(out, '[', ']', value, depth) { append(out, it, depth + 1) }
            is String -> string(out, value)
            is Boolean, is Int, is Long -> out.append(value.toString())
            else -> out.append("null")
        }
    }

    private fun <T> container(
        out: StringBuilder,
        open: Char,
        close: Char,
        items: List<T>,
        depth: Int,
        item: (T) -> Unit,
    ) {
        out.append(open)
        if (items.isNotEmpty()) {
            out.append('\n')
            items.forEachIndexed { index, value ->
                repeat(depth + 1) { out.append("  ") }
                item(value)
                out.append(if (index < items.lastIndex) ",\n" else "\n")
            }
            repeat(depth) { out.append("  ") }
        }
        out.append(close)
    }

    private fun string(out: StringBuilder, value: String) {
        out.append('"')
        value.forEach { char ->
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char == '\n' -> out.append("\\n")
                char == '\r' -> out.append("\\r")
                char == '\t' -> out.append("\\t")
                char < ' ' -> out.append("\\u").append(char.code.toString(16).padStart(4, '0'))
                else -> out.append(char)
            }
        }
        out.append('"')
    }
}
