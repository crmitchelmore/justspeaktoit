package com.justspeaktoit.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudKitSignInTest {
    private fun head(target: String, vararg fields: Pair<String, String>) =
        LoopbackRequestHead("GET", target, listOf("Host" to "127.0.0.1:47823") + fields)

    @Test
    fun testWebAuthToken_isPercentDecodedAndKeepsPlus() {
        assertEquals("a+b/c=", CloudKitSignIn.webAuthToken("/cloudkit-sign-in?x=1&ckWebAuthToken=a+b%2Fc%3D"))
        assertEquals("tok", CloudKitSignIn.webAuthToken("/cloudkit-%73ign-in?ckWebAuthToken=tok#frag"))
    }

    @Test
    fun testWebAuthToken_rejectsOtherPathsAndMalformedTargets() {
        assertNull(CloudKitSignIn.webAuthToken("/other?ckWebAuthToken=tok"))
        assertNull(CloudKitSignIn.webAuthToken("/cloudkit-sign-in"))
        assertNull(CloudKitSignIn.webAuthToken("/cloudkit-sign-in?ckWebAuthToken="))
        assertNull(CloudKitSignIn.webAuthToken("/cloudkit-sign-in?ckWebAuthToken"))
        assertNull(CloudKitSignIn.webAuthToken("/cloudkit-sign-in?ckWebAuthToken=a b"))
        assertNull(CloudKitSignIn.webAuthToken("/cloudkit-sign-in?ckWebAuthToken=%zz"))
    }

    @Test
    fun testRequestHead_parsesTheRequestLineAndFields() {
        val parsed = LoopbackRequestHead.parse(
            "GET /cloudkit-sign-in?ckWebAuthToken=t HTTP/1.1\r\nHost: 127.0.0.1:47823\r\nReferer: https://idmsa.apple.com/\r\n\r\n"
                .toByteArray(),
        )!!
        assertEquals("GET", parsed.method)
        assertEquals(listOf("https://idmsa.apple.com/"), parsed.values("referer"))
        assertNull(LoopbackRequestHead.parse("nonsense".toByteArray()))
    }

    @Test
    fun testCallback_acceptsATopLevelNavigationFromApple() {
        val decision = CloudKitSignIn.evaluateCallback(
            head(
                "/cloudkit-sign-in?ckWebAuthToken=tok",
                "Referer" to "https://www.icloud.com/",
                "Sec-Fetch-Mode" to "navigate",
                "Sec-Fetch-Dest" to "document",
                "Sec-Fetch-Site" to "cross-site",
            ),
        )
        assertEquals(CallbackDecision.Accept("tok"), decision)
    }

    @Test
    fun testCallback_refusesUntrustedRequests() {
        val target = "/cloudkit-sign-in?ckWebAuthToken=tok"
        assertEquals(CallbackDecision.NotFound, CloudKitSignIn.evaluateCallback(head("/favicon.ico")))
        assertEquals(CallbackDecision.NotFound, CloudKitSignIn.evaluateCallback(null))
        assertEquals(
            CallbackDecision.Refuse(CallbackRefusal.Method),
            CloudKitSignIn.evaluateCallback(LoopbackRequestHead("POST", target, listOf("Host" to "127.0.0.1"))),
        )
        assertEquals(
            CallbackDecision.Refuse(CallbackRefusal.Host),
            CloudKitSignIn.evaluateCallback(LoopbackRequestHead("GET", target, listOf("Host" to "localhost:47823"))),
        )
        assertEquals(
            CallbackDecision.Refuse(CallbackRefusal.NotTopLevelNavigation),
            CloudKitSignIn.evaluateCallback(head(target, "Sec-Fetch-Mode" to "cors")),
        )
        assertEquals(
            CallbackDecision.Refuse(CallbackRefusal.UntrustedInitiator),
            CloudKitSignIn.evaluateCallback(head(target, "Origin" to "https://evil.example")),
        )
    }

    @Test
    fun testTrustedSignInUrl_onlyAllowsAppleOverHttps() {
        assertTrue(CloudKitSignIn.isTrustedSignInUrl("https://idmsa.apple.com/appleauth"))
        assertTrue(CloudKitSignIn.isTrustedSignInUrl("https://icloud.com"))
        assertFalse(CloudKitSignIn.isTrustedSignInUrl("http://idmsa.apple.com/"))
        assertFalse(CloudKitSignIn.isTrustedSignInUrl("https://apple.com.evil.example/"))
        assertFalse(CloudKitSignIn.isTrustedSignInUrl("https://notapple.com/"))
    }
}
