package com.justspeaktoit.android.sendtomac

import android.content.Context
import org.json.JSONObject

/**
 * The Send to Mac wire contract (protocol v2), read from `assets/send_to_mac_protocol.json`.
 *
 * SpeakCore's `SendToMacProtocolAndroidExport` writes that asset from the same constants the Mac
 * and iPhone use, with test vectors that `SendToMacProtocolVectorTest` replays byte for byte. Never
 * copy a label or size into Kotlin: read it from here, so the senders cannot drift apart.
 */
internal class SendToMacProtocol(
    val protocolVersion: Int,
    /** DNS-SD service type of the Stable Mac app; Android ships on the Stable train only. */
    val serviceType: String,
    val endpointPath: String,
    val handshakeFrameLimitBytes: Int,
    val sessionFrameLimitBytes: Int,
    val labels: Labels,
    val sizes: Sizes,
    /** What the Mac says when it no longer knows this phone's credential. */
    val revokedCredentialMessage: String,
) {
    class Labels(
        val transcript: String,
        val frameAssociatedData: String,
        val clientFinished: String,
        val serverFinished: String,
        val clientToServerInfo: String,
        val serverToClientInfo: String,
        val pairingKeySalt: String,
        val credentialKeySalt: String,
        val preSharedKeyInfo: String,
    )

    class Sizes(
        val key: Int,
        val tag: Int,
        val nonce: Int,
        val credentialId: Int,
        val credentialSecret: Int,
    )

    companion object {
        const val ASSET = "send_to_mac_protocol.json"

        /** The train this build belongs to; it picks the service type and goes in `hello`. */
        const val RELEASE_TRAIN = "stable"

        @Volatile private var cached: SendToMacProtocol? = null

        fun load(context: Context): SendToMacProtocol = cached ?: synchronized(this) {
            cached ?: context.assets.open(ASSET).bufferedReader().use { parse(it.readText()) }.also { cached = it }
        }

        fun parse(json: String): SendToMacProtocol {
            val root = JSONObject(json)
            val labels = root.getJSONObject("labels")
            val sizes = root.getJSONObject("sizes")
            return SendToMacProtocol(
                protocolVersion = root.getInt("protocolVersion"),
                serviceType = root.getJSONObject("serviceTypes").getString(RELEASE_TRAIN),
                endpointPath = root.getString("endpointPath"),
                handshakeFrameLimitBytes = root.getInt("handshakeFrameLimitBytes"),
                sessionFrameLimitBytes = root.getInt("sessionFrameLimitBytes"),
                labels = Labels(
                    transcript = labels.getString("transcript"),
                    frameAssociatedData = labels.getString("frameAssociatedData"),
                    clientFinished = labels.getString("clientFinished"),
                    serverFinished = labels.getString("serverFinished"),
                    clientToServerInfo = labels.getString("clientToServerInfo"),
                    serverToClientInfo = labels.getString("serverToClientInfo"),
                    pairingKeySalt = labels.getString("pairingKeySalt"),
                    credentialKeySalt = labels.getString("credentialKeySalt"),
                    preSharedKeyInfo = labels.getString("preSharedKeyInfo"),
                ),
                sizes = Sizes(
                    key = sizes.getInt("key"),
                    tag = sizes.getInt("tag"),
                    nonce = sizes.getInt("nonce"),
                    credentialId = sizes.getInt("credentialID"),
                    credentialSecret = sizes.getInt("credentialSecret"),
                ),
                revokedCredentialMessage = root.getString("revokedCredentialMessage"),
            )
        }
    }
}
