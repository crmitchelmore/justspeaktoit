package com.justspeaktoit.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import com.justspeaktoit.android.R
import com.justspeaktoit.android.cloud.CloudSharingConsent
import com.justspeaktoit.android.cloud.CloudSharingConsentStore
import com.justspeaktoit.android.cloud.CloudSharingProvider
import com.justspeaktoit.android.cloud.CloudSharingProviders
import com.justspeaktoit.android.cloud.CloudSharingRequest

/** The consent sheet. Dismissing it is Not now. */
@Composable
fun CloudSharingConsentDialog(
    request: CloudSharingRequest,
    onAllow: () -> Unit,
    onUseOnDevice: () -> Unit,
    onNotNow: () -> Unit,
) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onNotNow,
        modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_SHEET),
        title = { Text(request.title) },
        text = {
            Column {
                Text(request.message)
                if (request.provider.privacyPolicyUrl.isNotBlank()) {
                    TextButton(
                        onClick = {
                            context.startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(request.provider.privacyPolicyUrl))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        },
                        modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_POLICY),
                    ) {
                        Text(stringResource(R.string.cloud_sharing_policy, request.provider.displayName))
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onAllow, modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_ALLOW)) {
                Text(stringResource(R.string.cloud_sharing_allow))
            }
        },
        dismissButton = {
            Column {
                if (request.canUseOnDevice) {
                    TextButton(
                        onClick = onUseOnDevice,
                        modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_ON_DEVICE),
                    ) {
                        Text(stringResource(R.string.cloud_sharing_on_device))
                    }
                }
                TextButton(onClick = onNotNow, modifier = Modifier.testTag(AutomationIds.CLOUD_SHARING_NOT_NOW)) {
                    Text(stringResource(R.string.cloud_sharing_not_now))
                }
            }
        },
    )
}

/** Allowed providers, with Withdraw. The heading matches the settings search entry. */
@Composable
fun CloudSharingSettings(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val store = remember { CloudSharingConsentStore.preferences(context) }
    val providers = remember {
        try {
            context.assets.open("cloud_sharing_providers.json").bufferedReader().use {
                CloudSharingProviders.load(it.readText())
            }
        } catch (e: java.io.IOException) {
            emptyList()
        }
    }
    var consent by remember { mutableStateOf(store.consent()) }
    Column(modifier = modifier.fillMaxWidth().testTag(AutomationIds.CLOUD_SHARING_SETTINGS)) {
        Text(
            stringResource(R.string.settings_cloud_sharing_title),
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.semantics { heading() },
        )
        Text(stringResource(R.string.settings_cloud_sharing_note), style = MaterialTheme.typography.bodyMedium)
        val granted = consent.grantedProviderIds().mapNotNull { id ->
            providers.firstOrNull { it.id == id } ?: CloudSharingProvider(id, id, "")
        }
        if (granted.isEmpty()) {
            Text(stringResource(R.string.settings_cloud_sharing_empty), style = MaterialTheme.typography.bodyMedium)
        }
        granted.forEach { provider ->
            Text(provider.displayName, style = MaterialTheme.typography.titleMedium)
            Text(
                consent.grantedKinds(provider.id).joinToString(", ") { it.title },
                style = MaterialTheme.typography.bodyMedium,
            )
            TextButton(
                onClick = {
                    store.withdraw(provider.id)
                    consent = store.consent()
                },
                modifier = Modifier.testTag(AutomationIds.cloudSharingWithdraw(provider.id)),
            ) {
                Text(stringResource(R.string.cloud_sharing_withdraw))
            }
        }
    }
}
