package com.justspeaktoit.android.cloud

import java.text.Collator
import java.util.Locale

/**
 * The Mac's `ModelPickerGrouping` rule for Android: native routes first, then one OpenRouter entry
 * that opens its own list. Each group is alphabetical by provider (OpenRouter: vendor), then by model
 * name, case-insensitive and numeric-aware. Pure, so it is unit-tested.
 */
object CleanupModelPicker {
    const val OPENROUTER_SEPARATOR = " › "

    fun direct(models: List<CleanupModel> = CloudCatalog.cleanupModels): List<CleanupModel> =
        sorted(models.filterNot { it.isOpenRouter })

    fun openRouter(models: List<CleanupModel> = CloudCatalog.cleanupModels): List<CleanupModel> =
        sorted(models.filter { it.isOpenRouter })

    /** "OpenRouter › GPT-6 Luna" for an OpenRouter route, otherwise the model's own name. */
    fun selectionLabel(model: CleanupModel): String =
        if (model.isOpenRouter) CloudProvider.OpenRouter.displayName + OPENROUTER_SEPARATOR + model.displayName
        else model.displayName

    fun filter(models: List<CleanupModel>, query: String): List<CleanupModel> {
        val needle = query.trim().lowercase(Locale.ROOT)
        if (needle.isEmpty()) return models
        return models.filter {
            it.displayName.lowercase(Locale.ROOT).contains(needle) ||
                it.selectionId.lowercase(Locale.ROOT).contains(needle) ||
                it.vendor.lowercase(Locale.ROOT).contains(needle)
        }
    }

    fun sorted(models: List<CleanupModel>): List<CleanupModel> =
        models.sortedWith { a, b ->
            compareNatural(a.vendor, b.vendor).takeIf { it != 0 } ?: compareNatural(a.displayName, b.displayName)
        }

    /** Case-insensitive, locale-aware text with digit runs compared by value ("5.4" before "5.10"). */
    fun compareNatural(a: String, b: String): Int {
        val collator = Collator.getInstance(Locale.getDefault()).apply { strength = Collator.SECONDARY }
        val left = chunks(a)
        val right = chunks(b)
        for (i in 0 until minOf(left.size, right.size)) {
            val x = left[i]
            val y = right[i]
            val result = if (x.first().isDigit() && y.first().isDigit()) {
                x.toBigInteger().compareTo(y.toBigInteger())
            } else {
                collator.compare(x, y)
            }
            if (result != 0) return result
        }
        return left.size.compareTo(right.size)
    }

    private fun chunks(text: String): List<String> = Regex("\\d+|\\D+").findAll(text).map { it.value }.toList()
}
