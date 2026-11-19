package com.justspeaktoit.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.OpenRouterBrowser
import com.justspeaktoit.android.cloud.OpenRouterBrowserFilter
import com.justspeaktoit.android.cloud.OpenRouterBrowserItem
import com.justspeaktoit.android.cloud.OpenRouterDiscoveryState

/**
 * The OpenRouter browser for batch transcription: the bundled speech-to-text models and those
 * OpenRouter lists today, with search, provider and price filters and a details page where the model
 * is chosen. Android's cloud transcription is batch only, so every listed model can be routed.
 */
@Composable
fun TranscriptionModelPickerDialog(
    selectedId: String,
    savedKeys: Set<CloudProvider>,
    discovery: OpenRouterDiscoveryUi,
    onChoose: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var detail by remember { mutableStateOf<OpenRouterBrowserItem?>(null) }
    var filter by remember { mutableStateOf(OpenRouterBrowserFilter()) }
    val found = discovery.state.transcriptionModels
    val models = remember(found) { OpenRouterBrowser.transcriptionItems(found) }
    val copy = OpenRouterBrowserCopy.Transcription
    LaunchedEffect(Unit) { discovery.onRefreshTranscription(false) }
    val back: () -> Unit = { if (detail != null) detail = null else onDismiss() }

    ModelPickerScaffold(detail?.name ?: copy.title, copy.ids, back) {
        val shown = detail
        if (shown != null) {
            OpenRouterModelDetail(
                copy = copy,
                item = shown,
                isSelected = shown.selectionId.equals(selectedId, ignoreCase = true),
                hasKey = CloudProvider.OpenRouter in savedKeys,
                needsKey = needsKeyText(CloudProvider.OpenRouter, cleanup = false),
                onChoose = { onChoose(shown.selectionId) },
            )
        } else {
            OpenRouterModelList(
                copy = copy,
                models = models,
                filter = filter,
                isSelected = { it.selectionId.equals(selectedId, ignoreCase = true) },
                discovery = OpenRouterDiscoveryControls(
                    loading = discovery.state.transcriptionLoading,
                    failed = discovery.state.transcriptionFailed,
                    onRefresh = { discovery.onRefreshTranscription(true) },
                ),
                onFilter = { filter = it },
                onOpen = { detail = it },
            )
        }
    }
}

/**
 * "OpenRouter › name" for an OpenRouter transcription model, using the browser's name for it (a live
 * model's listed name rather than its slug); null for any other provider.
 */
fun openRouterTranscriptionLabel(model: CloudModel, discovery: OpenRouterDiscoveryState): String? {
    if (model.provider != CloudProvider.OpenRouter) return null
    val name = OpenRouterBrowser.transcriptionItems(discovery.transcriptionModels)
        .firstOrNull { it.selectionId.equals(model.catalogId, ignoreCase = true) }?.name
        ?: model.displayName
    return OpenRouterBrowser.selectionLabel(name)
}
