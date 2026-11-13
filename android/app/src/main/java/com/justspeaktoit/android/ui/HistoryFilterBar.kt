package com.justspeaktoit.android.ui

import android.app.DatePickerDialog
import android.content.DialogInterface
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.history.HistoryFilter
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * History search plus model, errors-only and date filters. They only change which entries are shown,
 * never the stored History.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun HistoryFilterBar(
    filter: HistoryFilter,
    models: List<String>,
    modelName: (String) -> String,
    onChange: (HistoryFilter) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = filter.searchText,
            onValueChange = { onChange(filter.copy(searchText = it)) },
            label = { Text(stringResource(R.string.history_search_label)) },
            leadingIcon = {
                // Decorative: the field's label already says what it searches.
                Icon(painterResource(R.drawable.ic_search), contentDescription = null)
            },
            trailingIcon = {
                if (filter.searchText.isNotEmpty()) {
                    IconButton(
                        onClick = { onChange(filter.copy(searchText = "")) },
                        modifier = Modifier.testTag(AutomationIds.HISTORY_SEARCH_CLEAR),
                    ) {
                        Icon(painterResource(R.drawable.ic_close), stringResource(R.string.history_search_clear))
                    }
                }
            },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(AutomationIds.HISTORY_SEARCH),
        )
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ModelFilter(filter.model, models, modelName) { onChange(filter.copy(model = it)) }
            FilterChip(
                selected = filter.errorsOnly,
                onClick = { onChange(filter.copy(errorsOnly = !filter.errorsOnly)) },
                label = { Text(stringResource(R.string.history_filter_errors_only)) },
                modifier = Modifier.testTag(AutomationIds.HISTORY_FILTER_ERRORS),
            )
            val today = LocalDate.now(ZoneId.systemDefault())
            DayFilter(
                label = R.string.history_filter_from,
                day = filter.fromDay,
                earliest = null,
                latest = filter.throughDay ?: today,
                onPick = { onChange(filter.copy(fromDay = it)) },
                modifier = Modifier.testTag(AutomationIds.HISTORY_FILTER_FROM),
            )
            DayFilter(
                label = R.string.history_filter_through,
                day = filter.throughDay,
                earliest = filter.fromDay,
                latest = maxOf(today, filter.fromDay ?: today),
                onPick = { onChange(filter.copy(throughDay = it)) },
                modifier = Modifier.testTag(AutomationIds.HISTORY_FILTER_THROUGH),
            )
            if (filter.isActive) {
                TextButton(
                    onClick = { onChange(HistoryFilter()) },
                    modifier = Modifier.testTag(AutomationIds.HISTORY_FILTER_CLEAR),
                ) {
                    Text(stringResource(R.string.history_filter_clear))
                }
            }
        }
    }
}

@Composable
private fun ModelFilter(
    selected: String?,
    models: List<String>,
    modelName: (String) -> String,
    onChoose: (String?) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val allModels = stringResource(R.string.history_filter_all_models)
    Box {
        OutlinedButton(
            onClick = { open = true },
            modifier = Modifier.testTag(AutomationIds.HISTORY_FILTER_MODEL),
        ) {
            Text(stringResource(R.string.history_filter_model, selected?.let(modelName) ?: allModels))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(allModels) },
                onClick = {
                    onChoose(null)
                    open = false
                },
                modifier = Modifier.testTag(AutomationIds.HISTORY_FILTER_MODEL_ALL),
            )
            models.forEach { key ->
                DropdownMenuItem(
                    text = { Text(modelName(key)) },
                    onClick = {
                        onChoose(key)
                        open = false
                    },
                    modifier = Modifier.testTag(AutomationIds.historyFilterModel(key)),
                )
            }
        }
    }
}

/** A button showing one end of the date range; it opens the system date picker, whose "Any day" clears it. */
@Composable
private fun DayFilter(
    @StringRes label: Int,
    day: LocalDate?,
    earliest: LocalDate?,
    latest: LocalDate,
    onPick: (LocalDate?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val anyDay = stringResource(R.string.history_filter_any_day)
    var dialog by remember { mutableStateOf<DatePickerDialog?>(null) }
    DisposableEffect(Unit) { onDispose { dialog?.dismiss() } }
    OutlinedButton(
        onClick = {
            val zone = ZoneId.systemDefault()
            val initial = day ?: latest
            val picker = DatePickerDialog(
                context,
                DatePickerDialog.OnDateSetListener { _, year, month, dayOfMonth ->
                    onPick(LocalDate.of(year, month + 1, dayOfMonth))
                },
                initial.year,
                initial.monthValue - 1,
                initial.dayOfMonth,
            )
            earliest?.let { picker.datePicker.minDate = it.atStartOfDay(zone).toInstant().toEpochMilli() }
            picker.datePicker.maxDate = latest.atStartOfDay(zone).toInstant().toEpochMilli()
            picker.setButton(
                DialogInterface.BUTTON_NEUTRAL,
                anyDay,
                DialogInterface.OnClickListener { _, _ -> onPick(null) },
            )
            picker.show()
            dialog = picker
        },
        modifier = modifier,
    ) {
        val shown = day?.let { DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).format(it) } ?: anyDay
        Text(stringResource(label, shown))
    }
}
