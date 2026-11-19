package com.justspeaktoit.android.settings

import androidx.annotation.StringRes
import com.justspeaktoit.android.R

/**
 * The API keys status filters, mirroring SpeakCore's `APIKeyStatusFilter` (APIKeyListQuery.swift):
 * same cases, order, labels and predicate. `ApiKeyStatusFilterTest` fails if they drift.
 */
enum class ApiKeyStatusFilter(@StringRes val label: Int, @StringRes val emptyMessage: Int) {
    All(R.string.settings_keys_filter_all, R.string.settings_keys_empty_all),
    Errors(R.string.settings_keys_filter_errors, R.string.settings_keys_empty_errors),
    Stored(R.string.settings_keys_filter_set, R.string.settings_keys_empty_set),
    Missing(R.string.settings_keys_filter_unset, R.string.settings_keys_empty_unset),
    ;

    fun matches(saved: Boolean, hasError: Boolean): Boolean = when (this) {
        All -> true
        Errors -> hasError
        Stored -> saved
        Missing -> !saved
    }
}
