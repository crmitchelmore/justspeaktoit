package com.justspeaktoit.android.settings

import com.justspeaktoit.android.cloud.RepoSources
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ApiKeyStatusFilterTest {
    private fun visible(filter: ApiKeyStatusFilter) = listOf(
        Triple("unset", false, false),
        Triple("set", true, false),
        Triple("broken", true, true),
        Triple("unreadable", false, true),
    ).filter { (_, saved, failed) -> filter.matches(saved, failed) }.map { it.first }

    @Test
    fun testFilters_showOnlyMatchingKeys() {
        assertEquals(listOf("unset", "set", "broken", "unreadable"), visible(ApiKeyStatusFilter.All))
        assertEquals(listOf("broken", "unreadable"), visible(ApiKeyStatusFilter.Errors))
        assertEquals(listOf("set", "broken"), visible(ApiKeyStatusFilter.Stored))
        assertEquals(listOf("unset", "unreadable"), visible(ApiKeyStatusFilter.Missing))
    }

    @Test
    fun testFilters_matchSharedSwiftCasesAndLabels() {
        val swift = RepoSources.speakCore("APIKeyListQuery.swift")
        val cases = Regex("""^\s+case (\w+)$""", RegexOption.MULTILINE)
            .findAll(swift.substringAfter("enum APIKeyStatusFilter").substringBefore("public var id"))
            .map { it.groupValues[1] }.toList()
        assertEquals(cases, ApiKeyStatusFilter.entries.map { it.name.replaceFirstChar(Char::lowercase) })
        val strings = File("src/main/res/values/strings.xml").readText()
        val labels = mapOf("all" to "All", "errors" to "Errors", "set" to "Set", "unset" to "Unset")
        labels.forEach { (key, label) ->
            val resource = "name=\"settings_keys_filter_$key\">$label</string>"
            assertTrue("settings_keys_filter_$key drifted", strings.contains(resource))
            assertTrue("Swift label $label missing", swift.contains("return \"$label\""))
        }
    }
}
