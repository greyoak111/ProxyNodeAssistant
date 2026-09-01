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

    @Test fun ss2022OnlyHandoffIsAcceptedAsUsefulRuntimeData() {
        val value = "${ProtocolParsers.HANDOFF_BEGIN}\nHANDOFF_RUN_STARTED=run-ss\nSS2022_LINK=ss://redacted@203.0.113.10:30443#ProxyNodeAssistant-SS2022-TCP\nSS2022_PORT=30443\n${ProtocolParsers.HANDOFF_END}"
        assertTrue(ProtocolParsers.handoff(value).contains("SS2022_PORT=30443"))
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
        val value = "${ProtocolParsers.TOOLKIT_BEGIN}\nTOOLKIT_PRESENT=1\nTOOLKIT_VERSION=v1.0.0\nTOOLKIT_BUILD_ID=20260901-v100-ss2022-r102\nTOOLKIT_BUILD_REVISION=102\nTOOLKIT_COMPLETE=1\n${ProtocolParsers.TOOLKIT_END}"
        val probe = ProtocolParsers.toolkit(value)
        assertTrue(probe.installed)
        assertTrue(probe.complete)
        assertEquals(102, probe.buildRevision)
        assertTrue(ProtocolParsers.compareVersions("0.10.0", "0.9.9") > 0)
        assertEquals(0, ProtocolParsers.compareVersions("v0.9", "0.9.0"))
    }
}
