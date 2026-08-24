package com.proxynodeassistant.android.remote

import com.proxynodeassistant.android.data.DeviceIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceAdmissionProtocolTest {
    @Test
    fun statusAndInvitationRoundTrip() {
        val status = DeviceAdmissionProtocol.parseStatus(
            """
            __PNA_DEVICE_STATUS_V1_BEGIN__
            NODE_ID=pna-node-0123456789abcdef0123456789abcdef
            CONTROLLER_ACTIVE_COUNT=1
            DEVICE_ACTIVE_COUNT=1
            DEVICE	pna-device-abcdefghijklmnopqrstuvwxyz	controller	active	Android Phone	2026-08-24T12:00:00Z
            PER_DEVICE_VLESS=SUPPORTED
            CDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED
            WIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED
            __PNA_DEVICE_STATUS_V1_END__
			""".trimIndent().replace("\\t", "\t"),
        )
        assertEquals(1, status.activeControllers)
        assertEquals("Android Phone", status.devices.single().label)

    }

    @Test
    fun signedResponseKeepsCanonicalFields() {
        val invite = DeviceInvite(
            "pna-node-0123456789abcdef0123456789abcdef",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            System.currentTimeMillis() / 1000 + 600,
        )
        val identity = DeviceIdentity("pna-device-abcdefghijklmnopqrstuvwxyz", "pna-ed25519:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 1)
        val response = DeviceAdmissionProtocol.response(invite, identity, "Android Phone", "traffic-only") { "A".repeat(86) }
		assertEquals(identity.deviceId, response.deviceId)
		assertTrue(DeviceAdmissionProtocol.signingBytes(response).toString(Charsets.UTF_8).endsWith("ROLE=traffic-only\n"))
    }
}
