package com.proxynodeassistant.android.remote

import android.util.Base64
import com.proxynodeassistant.android.data.DeviceIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.security.MessageDigest

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DeviceAdmissionProtocolTest {
    @Test
    fun statusAcceptsCurrentAndLegacyMarkers() {
        val status = DeviceAdmissionProtocol.parseStatus(
            """
            __TNA_DEVICE_STATUS_V1_BEGIN__
            NODE_ID=tna-node-0123456789abcdef0123456789abcdef
            CONTROLLER_ACTIVE_COUNT=1
            DEVICE_ACTIVE_COUNT=1
            DEVICE	tna-device-abcdefghijklmnopqrstuvwxyz	controller	active	Android Phone	2026-08-24T12:00:00Z
            PER_DEVICE_VLESS=SUPPORTED
            CDN_MTLS_DEVICE=EXPERIMENTAL_BLOCKED
            WIREGUARD_DEVICE_LOCK=EXPERIMENTAL_BLOCKED
            __TNA_DEVICE_STATUS_V1_END__
            """.trimIndent(),
        )
        assertEquals(1, status.activeControllers)
        assertEquals("Android Phone", status.devices.single().label)
    }

    @Test
    fun invitationAndSignedResponseKeepV2BindingFields() {
        val known = "example.com ssh-ed25519 ${Base64.encodeToString(ByteArray(32), Base64.NO_WRAP)}"
        val invite = DeviceInvite(
            nodeId = "tna-node-0123456789abcdef0123456789abcdef",
            nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            host = "example.com",
            user = "root",
            port = 22,
            knownHosts = known,
        )
        assertEquals(invite, DeviceAdmissionProtocol.decodeInvite(DeviceAdmissionProtocol.encodeInvite(invite)))

        val rawPublic = ByteArray(32)
        val identity = DeviceIdentity(
            version = 2,
            deviceId = "tna-device-${base32(MessageDigest.getInstance("SHA-256").digest(rawPublic).copyOfRange(0, 16))}",
            publicValue = "tna-ed25519:${Base64.encodeToString(rawPublic, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)}",
            encryptionPublic = "tna-x25519:${Base64.encodeToString(ByteArray(32), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)}",
            createdEpochMs = 1,
        )
        val response = DeviceAdmissionProtocol.response(invite, identity, "Android Phone", "traffic-only", "ssh-ed25519 ${"A".repeat(68)}") { "A".repeat(86) }
        assertEquals(identity.deviceId, response.deviceId)
        val message = DeviceAdmissionProtocol.signingBytes(response).toString(Charsets.UTF_8)
        assertTrue(message.startsWith("TNA-DEVICE-ENROLL-V2\n"))
        assertTrue(message.endsWith("SSH_PUBLIC_KEY=ssh-ed25519 ${"A".repeat(68)}\n"))
        assertEquals(response, DeviceAdmissionProtocol.decodeResponse(DeviceAdmissionProtocol.encodeResponse(response)))
        assertEquals(8, DeviceAdmissionProtocol.enrollmentInput(response).toString(Charsets.UTF_8).trimEnd().lines().size)
    }

    @Test(expected = IllegalArgumentException::class)
    fun invitationRejectsPinnedKeyForAnotherHost() {
        val invite = DeviceInvite(
            nodeId = "tna-node-0123456789abcdef0123456789abcdef",
            nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            host = "expected.example.com",
            user = "root",
            port = 22,
            knownHosts = "other.example.com ssh-ed25519 ${Base64.encodeToString(ByteArray(32), Base64.NO_WRAP)}",
        )
        DeviceAdmissionProtocol.encodeInvite(invite)
    }

    private fun base32(bytes: ByteArray): String {
        val alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        val output = StringBuilder()
        var buffer = 0
        var bits = 0
        for (value in bytes) {
            buffer = (buffer shl 8) or (value.toInt() and 0xff)
            bits += 8
            while (bits >= 5) { bits -= 5; output.append(alphabet[(buffer shr bits) and 31]) }
        }
        if (bits > 0) output.append(alphabet[(buffer shl (5 - bits)) and 31])
        return output.toString()
    }
}
