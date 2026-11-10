package com.justspeaktoit.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Source guards for the conventions in Docs/accessibility.md. */
class AccessibilitySourceTest {
    private val main = File("src/main").absoluteFile
    private val kotlin = main.walkTopDown().filter { it.extension == "kt" }.toList()

    @Test
    fun testNullContentDescription_isMarkedDecorative() {
        kotlin.forEach { file ->
            val lines = file.readLines()
            lines.forEachIndexed { index, line ->
                if (line.contains("contentDescription = null")) {
                    assertTrue(
                        "${file.name}:${index + 1} hides an image without a `// Decorative:` reason",
                        index > 0 && lines[index - 1].trim().startsWith("// Decorative:"),
                    )
                }
            }
        }
    }

    @Test
    fun testCustomClickables_declareRoleAndLabel() {
        kotlin.forEach { file ->
            val lines = file.readLines()
            lines.forEachIndexed { index, line ->
                if (line.contains(".clickable(")) {
                    val semantics = lines.subList(index, minOf(lines.size, index + 6)).joinToString("\n")
                    assertTrue("${file.name}:${index + 1} clickable lacks a role", semantics.contains("role = Role."))
                    assertTrue(
                        "${file.name}:${index + 1} clickable lacks a label",
                        semantics.contains("contentDescription ="),
                    )
                }
            }
        }
    }

    @Test
    fun testAutomationIds_areUniqueUsedAndExposedAsResourceIds() {
        val declared = File(main, "java/com/justspeaktoit/android/ui/AutomationIds.kt").readText()
        val ids = Regex("""const val (\w+) = "([^"]+)"""").findAll(declared).map { it.groupValues }.toList()
        assertTrue(ids.isNotEmpty())
        assertEquals("Automation IDs must be unique", ids.size, ids.map { it[2] }.toSet().size)
        val screens = kotlin.filter { it.name != "AutomationIds.kt" }.joinToString("\n") { it.readText() }
        ids.forEach { assertTrue("${it[1]} is never applied", screens.contains("AutomationIds.${it[1]})")) }
        val activity = File(main, "java/com/justspeaktoit/android/MainActivity.kt").readText()
        assertTrue("Test tags must be exposed as resource IDs", activity.contains("testTagsAsResourceId = true"))
    }

    @Test
    fun testKeyboardViews_haveStableResourceIds() {
        val ids = Regex("""name="(keyboard_\w+)" type="id"""")
            .findAll(File(main, "res/values/ids.xml").readText()).map { it.groupValues[1] }.toList()
        val keyboard = File(main, "java/com/justspeaktoit/android/ime/DictationKeyboardService.kt").readText()
        assertTrue(ids.isNotEmpty())
        ids.forEach { assertTrue("$it is not assigned to a keyboard view", keyboard.contains("R.id.$it")) }
        val created = Regex("""= (TextView|ImageButton|Button)\(this\)""").findAll(keyboard).count()
        val assigned = Regex("""\bid = (R\.id\.|viewId)""").findAll(keyboard).count()
        assertEquals("Every keyboard view needs a resource ID", created, assigned)
    }
}
