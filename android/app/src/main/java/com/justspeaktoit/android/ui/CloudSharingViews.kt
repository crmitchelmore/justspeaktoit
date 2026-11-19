package com.justspeaktoit.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CloudSharingConsent
import com.justspeaktoit.android.cloud.CloudSharingRequest
import com.justspeaktoit.android.cloud.GeneratedCloudCatalog

/**
 * Asks before content first goes to a cloud AI provider (#1805): names each provider, the content it gets
 * and its privacy policy. The copy is SpeakCore's, exported in `cloud_catalog.json`. Dismissing is Not now.
 */
@Composable
internal fun CloudSharingConsentDialog(
    requests: List<CloudSharingRequest>,
    offersOnDevice: Boolean,
    onAllow: () -> Unit,
    onUseOnDevice: () -> Unit,
    onNotNow: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onNotNow,
        modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_DIALOG),
        title = {
            Text(GeneratedCloudCatalog.CLOUD_SHARING_SHEET_TITLE, modifier = Modifier.semantics { heading() })
        },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Text(CloudSharingConsent.sheetIntro(requests))
                requests.forEach { CloudSharingProviderSummary(it) }
            }
        },
        confirmButton = {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Button(onClick = onAllow, modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_ALLOW)) {
                    Text(GeneratedCloudCatalog.CLOUD_SHARING_ALLOW)
                }
                if (offersOnDevice) {
                    OutlinedButton(
                        onClick = onUseOnDevice,
                        modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_ON_DEVICE),
                    ) {
                        Text(GeneratedCloudCatalog.CLOUD_SHARING_USE_ON_DEVICE)
                    }
                }
                TextButton(onClick = onNotNow, modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_NOT_NOW)) {
                    Text(GeneratedCloudCatalog.CLOUD_SHARING_NOT_NOW)
                }
            }
        },
    )
}

/** One provider: its name, what it receives and a link to its privacy policy. */
@Composable
private fun CloudSharingProviderSummary(request: CloudSharingRequest) {
    val uriHandler = LocalUriHandler.current
    Column(
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.testTag(AutomationIds.cloudSharingProvider(request.provider.id)),
    ) {
        Text(request.provider.displayName, style = MaterialTheme.typography.titleSmall)
        request.kindLines.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
        request.provider.privacyPolicyUrl?.let { url ->
            TextButton(
                onClick = { uriHandler.openUri(url) },
                modifier = Modifier.testTag(AutomationIds.cloudSharingPolicy(request.provider.id)),
            ) {
                Text(stringResource(R.string.cloud_sharing_policy_link, request.provider.displayName))
            }
        }
    }
}

/** Settings > Privacy: the providers the user allowed, each with Withdraw. */
@Composable
internal fun CloudSharingSettingsSection(
    allowed: List<CloudSharingRequest>,
    onWithdraw: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = modifier) {
        Text(
            GeneratedCloudCatalog.CLOUD_SHARING_WITHDRAWAL_TITLE,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() },
        )
        if (allowed.isEmpty()) {
            Text(
                GeneratedCloudCatalog.CLOUD_SHARING_EMPTY,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.testTag(AutomationIds.SETTINGS_CLOUD_SHARING_EMPTY),
            )
        }
        allowed.forEach { request ->
            val name = request.provider.displayName
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(name, style = MaterialTheme.typography.bodyLarge)
                    Text(request.kinds.joinToString(", ") { it.title }, style = MaterialTheme.typography.bodySmall)
                }
                val description = stringResource(R.string.cloud_sharing_withdraw_description, name)
                TextButton(
                    onClick = { onWithdraw(request.provider.id) },
                    modifier = Modifier
                        .testTag(AutomationIds.cloudSharingWithdraw(request.provider.id))
                        .semantics { contentDescription = description },
                ) {
                    Text(stringResource(R.string.cloud_sharing_withdraw))
                }
            }
        }
        Text(GeneratedCloudCatalog.CLOUD_SHARING_WITHDRAWAL_FOOTER, style = MaterialTheme.typography.bodySmall)
    }
}
