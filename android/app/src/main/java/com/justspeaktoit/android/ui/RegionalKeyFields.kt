package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.AlibabaCredential
import com.justspeaktoit.android.cloud.AzureSpeechCredential
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.StepFunCredential
import java.util.Locale

/**
 * What a key needs beside it before it can be saved: Azure's region, Alibaba's region and
 * workspace, StepFun's region. Like the key draft, these are held only until Save, which stores
 * them inside the credential in the Apple apps' format.
 */
@Stable
internal class RegionalKeyDraft(private val provider: CloudProvider) {
    var azureRegion by mutableStateOf(AzureSpeechCredential.DEFAULT_REGION)
    var alibabaRegion by mutableStateOf<AlibabaCredential.Region?>(null)
    var alibabaWorkspace by mutableStateOf("")
    var stepFunRegion by mutableStateOf(StepFunCredential.Region.DEFAULT_FOR_NEW_KEYS)

    /** The credential Save stores for [entered]; null when it, or a field beside it, is invalid. */
    fun credential(entered: String): String? = when (provider) {
        CloudProvider.Azure -> AzureSpeechCredential.credentialsForSaving(entered, azureRegion)
        CloudProvider.Alibaba -> AlibabaCredential.credentialsForSaving(entered, alibabaRegion, alibabaWorkspace)
        CloudProvider.StepFun -> StepFunCredential.credentialsForSaving(entered, stepFunRegion)
        else -> entered.trim().takeIf { it.isNotEmpty() }
    }
}

@Composable
internal fun rememberRegionalKeyDraft(provider: CloudProvider, saved: Boolean): RegionalKeyDraft =
    remember(provider, saved) { RegionalKeyDraft(provider) }

/** The fields above a key that needs them; nothing for other providers. */
@Composable
internal fun RegionalKeyFields(
    provider: CloudProvider,
    draft: RegionalKeyDraft,
    azureEndpoint: String,
    actions: SettingsActions,
) {
    when (provider) {
        CloudProvider.Azure -> AzureFields(draft, azureEndpoint, actions)
        CloudProvider.Alibaba -> AlibabaFields(draft)
        CloudProvider.StepFun -> StepFunFields(draft)
        else -> Unit
    }
}

@Composable
private fun AzureFields(draft: RegionalKeyDraft, savedEndpoint: String, actions: SettingsActions) {
    val region = draft.azureRegion.trim().lowercase(Locale.ROOT)
    val regionInvalid = !AzureSpeechCredential.isValidRegion(region)
    OutlinedTextField(
        value = draft.azureRegion,
        onValueChange = { draft.azureRegion = it },
        label = { Text(stringResource(R.string.settings_azure_region)) },
        supportingText = {
            Text(
                stringResource(
                    if (regionInvalid) R.string.settings_azure_region_invalid else R.string.settings_azure_region_help,
                ),
            )
        },
        isError = regionInvalid,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false),
        modifier = Modifier.fillMaxWidth().testTag(AutomationIds.AZURE_REGION),
    )
    var endpoint by remember(savedEndpoint) { mutableStateOf(savedEndpoint) }
    val endpointInvalid = endpoint.isNotBlank() && AzureSpeechCredential.resourceOrigin(endpoint) == null
    OutlinedTextField(
        value = endpoint,
        onValueChange = { endpoint = it },
        label = { Text(stringResource(R.string.settings_azure_endpoint)) },
        supportingText = {
            Text(
                stringResource(
                    if (endpointInvalid) {
                        R.string.settings_azure_endpoint_invalid
                    } else {
                        R.string.settings_azure_endpoint_help
                    },
                ),
            )
        },
        isError = endpointInvalid,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
        modifier = Modifier.fillMaxWidth().testTag(AutomationIds.AZURE_ENDPOINT),
    )
    if (savedEndpoint.isNotEmpty()) {
        Text(
            stringResource(R.string.settings_azure_endpoint_saved, savedEndpoint),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(
            onClick = { actions.onSaveAzureEndpoint(endpoint) },
            enabled = endpoint.isNotBlank() && !endpointInvalid && endpoint.trim() != savedEndpoint,
            modifier = Modifier.testTag(AutomationIds.AZURE_ENDPOINT_SAVE),
        ) {
            Text(stringResource(R.string.settings_azure_endpoint_save))
        }
        if (savedEndpoint.isNotEmpty()) {
            TextButton(
                onClick = {
                    endpoint = ""
                    actions.onClearAzureEndpoint()
                },
                modifier = Modifier.testTag(AutomationIds.AZURE_ENDPOINT_CLEAR),
            ) {
                Text(stringResource(R.string.settings_azure_endpoint_clear))
            }
        }
    }
}

@Composable
private fun AlibabaFields(draft: RegionalKeyDraft) {
    Text(
        stringResource(R.string.settings_alibaba_help),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    var open by remember { mutableStateOf(false) }
    val regionName = draft.alibabaRegion?.displayName ?: stringResource(R.string.settings_key_not_set)
    Box {
        OutlinedButton(
            onClick = { open = true },
            modifier = Modifier.testTag(AutomationIds.ALIBABA_REGION),
        ) {
            Text(stringResource(R.string.settings_alibaba_region, regionName))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            AlibabaCredential.Region.entries.forEach { region ->
                DropdownMenuItem(
                    text = { Text(region.displayName) },
                    onClick = {
                        draft.alibabaRegion = region
                        open = false
                    },
                    modifier = Modifier.testTag(AutomationIds.alibabaRegionOption(region.id)),
                )
            }
        }
    }
    val workspace = draft.alibabaWorkspace.trim().lowercase(Locale.ROOT)
    val workspaceInvalid = workspace.isNotEmpty() && !AlibabaCredential.isValidWorkspace(workspace)
    OutlinedTextField(
        value = draft.alibabaWorkspace,
        onValueChange = { draft.alibabaWorkspace = it },
        label = { Text(stringResource(R.string.settings_alibaba_workspace)) },
        supportingText = if (workspaceInvalid) {
            { Text(stringResource(R.string.settings_alibaba_workspace_invalid)) }
        } else {
            null
        },
        isError = workspaceInvalid,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false),
        modifier = Modifier.fillMaxWidth().testTag(AutomationIds.ALIBABA_WORKSPACE),
    )
}

@Composable
private fun StepFunFields(draft: RegionalKeyDraft) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.settings_stepfun_region), style = MaterialTheme.typography.labelLarge)
        val regions = StepFunCredential.Region.entries
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth().testTag(AutomationIds.STEPFUN_REGION)) {
            regions.forEachIndexed { index, region ->
                SegmentedButton(
                    selected = region == draft.stepFunRegion,
                    onClick = { draft.stepFunRegion = region },
                    shape = SegmentedButtonDefaults.itemShape(index, regions.size),
                    modifier = Modifier.testTag(AutomationIds.stepFunRegionOption(region.id)),
                ) {
                    Text(region.displayName)
                }
            }
        }
        Text(
            stringResource(R.string.settings_stepfun_help),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
