package com.proxynodeassistant.android.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolParsersTest {
    @Test fun connectionClosedCannotBecomeHandoff() {
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.handoff("Connection to example.invalid closed.") }
    }

    @Test fun emptyMarkedHandoffIsRejected() {
        val value = "${ProtocolParsers.HANDOFF_BEGIN}\n${ProtocolParsers.HANDOFF_END}\n"
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.handoff(value) }
    }

    @Test fun runMarkerWithoutUsefulFieldsIsRejected() {
        val value = "${ProtocolParsers.HANDOFF_BEGIN}\nHANDOFF_RUN_STARTED=20260823-010203\n${ProtocolParsers.HANDOFF_END}\n"
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.handoff(value) }
    }

    @Test fun validHandoffSurvivesAnsiAndNoise() {
        val value = "noise\n\u001B[33m${ProtocolParsers.HANDOFF_BEGIN}\u001B[0m\nHANDOFF_RUN_STARTED=run-1\nPANEL_PORT=2053\nPANEL_USERNAME=operator\n${ProtocolParsers.HANDOFF_END}\nConnection closed."
        val parsed = ProtocolParsers.handoff(value)
        assertTrue(parsed.contains("PANEL_PORT=2053"))
        assertFalse(parsed.contains("Connection closed"))
    }

    @Test fun panelRequiresRealPortAndSafePath() {
        val emptyPort = "${ProtocolParsers.PANEL_BEGIN}\nPANEL_PORT=\nWEB_BASE_PATH=/safe/\n${ProtocolParsers.PANEL_END}"
        assertThrows(IllegalStateException::class.java) { ProtocolParsers.panel(emptyPort) }
        val unsafePath = "${ProtocolParsers.PANEL_BEGIN}\nPANEL_PORT=12345\nWEB_BASE_PATH=/safe/?x=1\n${ProtocolParsers.PANEL_END}"
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.panel(unsafePath) }
        val valid = "${ProtocolParsers.PANEL_BEGIN}\nPANEL_PORT=12345\nWEB_BASE_PATH=admin\nPANEL_METADATA_SOURCE=x-ui\n${ProtocolParsers.PANEL_END}"
        assertEquals(12345, ProtocolParsers.panel(valid).port)
        assertEquals("/admin/", ProtocolParsers.panel(valid).path)
    }

    @Test fun toolkitProbeAndVersionComparisonAreStrict() {
        val value = "${ProtocolParsers.TOOLKIT_BEGIN}\nTOOLKIT_PRESENT=1\nTOOLKIT_VERSION=v0.9.5\nTOOLKIT_BUILD_ID=build\nTOOLKIT_BUILD_REVISION=5\nTOOLKIT_COMPLETE=1\n${ProtocolParsers.TOOLKIT_END}"
        val probe = ProtocolParsers.toolkit(value)
        assertTrue(probe.installed)
        assertTrue(probe.complete)
        assertEquals(5, probe.buildRevision)
        assertTrue(ProtocolParsers.compareVersions("0.10.0", "0.9.9") > 0)
        assertTrue(ProtocolParsers.compareVersions("v0.9", "0.9.5") < 0)
    }

    @Test fun completeHandoffPreservesLegacyPrefix() {
        val legacy = "HANDOFF_RUN_STARTED=fixture\nFUTURE_FIELD=keep\nREALITY_CLIENT_1_LINK=fixture-one\nREALITY_CLIENT_2_LINK=fixture-two"
        val complete = ProtocolParsers.completeHandoff(legacy, mapOf("PNA_VERSION" to "0.9.5", "ACTIVE_MODE" to "ACTIVE_DIRECT"))
        assertTrue(complete.startsWith(legacy))
        assertEquals(legacy, complete.substring(0, legacy.length))
        assertTrue(complete.contains("FUTURE_FIELD=keep"))
    }

    @Test fun loginCredentialFormRequiresAndRendersAllFourValues() {
        val legacy = "HANDOFF_RUN_STARTED=fixture\nVPS_LOGIN_USER=root\nVPS_LOGIN_PASSWORD=vps-secret\nPANEL_USERNAME=panel-admin\nPANEL_PASSWORD=panel-secret"
        val form = ProtocolParsers.loginCredentialForm(legacy)
        val complete = ProtocolParsers.completeHandoff(legacy, form)
        assertTrue(complete.contains("VPS_ACCOUNT=root"))
        assertTrue(complete.contains("VPS_PASSWORD=vps-secret"))
        assertTrue(complete.contains("PANEL_ACCOUNT=panel-admin"))
        assertTrue(complete.contains("PANEL_PASSWORD=panel-secret"))
        assertThrows(IllegalArgumentException::class.java) {
            ProtocolParsers.loginCredentialForm(legacy.replace("PANEL_PASSWORD=panel-secret", "PANEL_PASSWORD=UNKNOWN_NOT_RECOVERABLE"))
        }
    }

    @Test fun cdnXHttpLinkParserIsStrict() {
        val link = "vless://11111111-1111-4111-8111-111111111111@edge.example.com:443?encryption=none&security=tls&sni=edge.example.com&fp=chrome&type=xhttp&host=edge.example.com&path=%2F0123456789abcdef0123456789abcdef%2F&mode=packet-up#PNA-CDN-XHTTP"
        val parsed = ProtocolParsers.cdnXHttpLink(link)
        assertEquals("edge.example.com", parsed.domain)
        assertEquals("/0123456789abcdef0123456789abcdef/", parsed.path)
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.cdnXHttpLink(link.replace("security=tls", "security=none")) }
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.cdnXHttpLink("$link&security=tls") }
    }

	@Test fun stableNodeIdentityAndPublicIpv4AreStrict() {
		val value = "${ProtocolParsers.NODE_IDENTITY_BEGIN}\n" +
			"SERVER_ID=pna-srv-0123456789abcdef0123456789abcdef\n" +
			"NODE_ID=pna-node-0123456789abcdef0123456789abcdef\n" +
			"MACHINE_ID_SHA256=${"a".repeat(64)}\nMACHINE_ID_MATCH=1\n" +
			"SSH_HOST_KEY_SHA256=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nSSH_HOST_KEY_MATCH=1\n" +
			"FIRST_KNOWN_PUBLIC_IP=8.8.8.8\nCURRENT_PUBLIC_IP=1.1.1.1\n${ProtocolParsers.NODE_IDENTITY_END}"
		assertEquals("pna-node-0123456789abcdef0123456789abcdef", ProtocolParsers.stableNodeIdentity(value, "root@old:22").nodeId)
		assertTrue(ProtocolParsers.validCanonicalPublicIpv4("8.8.8.8"))
		assertFalse(ProtocolParsers.validCanonicalPublicIpv4("192.0.2.1"))
		assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.stableNodeIdentity(value.replace("MACHINE_ID_MATCH=1", "MACHINE_ID_MATCH=0"), "root@old:22") }
	}
}
