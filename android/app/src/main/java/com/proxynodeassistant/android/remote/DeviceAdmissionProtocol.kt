package com.proxynodeassistant.android.remote

import android.util.Base64
import com.proxynodeassistant.android.data.DeviceIdentity
import org.json.JSONObject

data class DeviceInvite(val nodeId: String, val nonce: String, val expiresEpoch: Long)
data class DeviceEnrollmentResponse(
    val nodeId: String,
    val nonce: String,
    val deviceId: String,
    val publicValue: String,
    val label: String,
    val role: String,
    val signature: String,
)

data class DeviceStatusRecord(val deviceId: String, val role: String, val status: String, val label: String, val createdAt: String)
data class DeviceAdmissionStatus(val nodeId: String, val activeControllers: Int, val activeDevices: Int, val devices: List<DeviceStatusRecord>)

object DeviceAdmissionProtocol {
    private val nodeId = Regex("^pna-node-[0-9a-f]{32}$")
    private val deviceId = Regex("^pna-device-[a-z2-7]{26}$")
    private val publicValue = Regex("^pna-ed25519:[A-Za-z0-9_-]{43}$")
    private val nonce = Regex("^[0-9a-f]{64}$")
    private val signature = Regex("^[A-Za-z0-9_-]{86}$")
    private val label = Regex("^[A-Za-z0-9._ -]{1,64}$")

    fun parseStatus(text: String): DeviceAdmissionStatus {
        val block = marker(text, "__PNA_DEVICE_STATUS_V1_BEGIN__", "__PNA_DEVICE_STATUS_V1_END__")
        val values = linkedMapOf<String, String>()
        val devices = mutableListOf<DeviceStatusRecord>()
        block.lines().filter { it.isNotBlank() }.forEach { line ->
            if (line.startsWith("DEVICE\t")) {
                val parts = line.split('\t')
                require(parts.size == 6 && deviceId.matches(parts[1]) && parts[2] in setOf("controller", "traffic-only") && parts[3] in setOf("active", "paused", "revoked", "REVOCATION_PARTIAL") && label.matches(parts[4])) { "Invalid device status row" }
                devices += DeviceStatusRecord(parts[1], parts[2], parts[3], parts[4], parts[5])
            } else {
                val parts = line.split('=', limit = 2)
                require(parts.size == 2 && parts[0] in setOf("NODE_ID", "CONTROLLER_ACTIVE_COUNT", "DEVICE_ACTIVE_COUNT", "PER_DEVICE_VLESS", "CDN_MTLS_DEVICE", "WIREGUARD_DEVICE_LOCK")) { "Invalid device status field" }
                values[parts[0]] = parts[1]
            }
        }
        require(nodeId.matches(values.getValue("NODE_ID")))
        require(values["PER_DEVICE_VLESS"] == "SUPPORTED" && values["CDN_MTLS_DEVICE"] == "EXPERIMENTAL_BLOCKED" && values["WIREGUARD_DEVICE_LOCK"] == "EXPERIMENTAL_BLOCKED")
        return DeviceAdmissionStatus(values.getValue("NODE_ID"), values.getValue("CONTROLLER_ACTIVE_COUNT").toInt().also { require(it >= 0) }, values.getValue("DEVICE_ACTIVE_COUNT").toInt().also { require(it >= 0) }, devices)
    }

    fun parseInviteOutput(text: String): DeviceInvite {
        val values = kv(marker(text, "__PNA_DEVICE_INVITE_V1_BEGIN__", "__PNA_DEVICE_INVITE_V1_END__"))
        return DeviceInvite(values.getValue("NODE_ID"), values.getValue("ENROLLMENT_NONCE"), values.getValue("EXPIRES_EPOCH").toLong()).also(::validateInvite)
    }

    fun encodeInvite(invite: DeviceInvite): String {
        validateInvite(invite)
        return "PNAINV1.${encode(JSONObject().put("v", 1).put("node", invite.nodeId).put("nonce", invite.nonce).put("expires", invite.expiresEpoch).toString())}"
    }

    fun decodeInvite(bundle: String): DeviceInvite {
        require(bundle.startsWith("PNAINV1.")) { "Invalid invitation prefix" }
        val item = JSONObject(decode(bundle.removePrefix("PNAINV1."), 2048))
        require(item.getInt("v") == 1)
        return DeviceInvite(item.getString("node"), item.getString("nonce"), item.getLong("expires")).also(::validateInvite)
    }

    fun signingBytes(response: DeviceEnrollmentResponse): ByteArray = buildString {
        appendLine("PNA-DEVICE-ENROLL-V1")
        appendLine("NODE_ID=${response.nodeId}")
        appendLine("NONCE=${response.nonce}")
        appendLine("DEVICE_ID=${response.deviceId}")
        appendLine("PUBLIC_KEY=${response.publicValue}")
        appendLine("LABEL=${response.label}")
        appendLine("ROLE=${response.role}")
    }.toByteArray(Charsets.UTF_8)

    fun response(invite: DeviceInvite, identity: DeviceIdentity, labelValue: String, role: String, signer: (ByteArray) -> String): DeviceEnrollmentResponse {
        require(label.matches(labelValue) && role in setOf("controller", "traffic-only"))
        val unsigned = DeviceEnrollmentResponse(invite.nodeId, invite.nonce, identity.deviceId, identity.publicValue, labelValue, role, "")
        return unsigned.copy(signature = signer(signingBytes(unsigned))).also(::validateResponse)
    }

    fun encodeResponse(response: DeviceEnrollmentResponse): String {
        validateResponse(response)
        val item = JSONObject().put("v", 1).put("node", response.nodeId).put("nonce", response.nonce).put("device", response.deviceId)
            .put("public", response.publicValue).put("label", response.label).put("role", response.role).put("signature", response.signature)
        return "PNARESP1.${encode(item.toString())}"
    }

    fun decodeResponse(bundle: String): DeviceEnrollmentResponse {
        require(bundle.startsWith("PNARESP1.")) { "Invalid response prefix" }
        val item = JSONObject(decode(bundle.removePrefix("PNARESP1."), 4096))
        require(item.getInt("v") == 1)
        return DeviceEnrollmentResponse(item.getString("node"), item.getString("nonce"), item.getString("device"), item.getString("public"), item.getString("label"), item.getString("role"), item.getString("signature")).also(::validateResponse)
    }

    private fun validateInvite(invite: DeviceInvite) {
        val now = System.currentTimeMillis() / 1000
        require(nodeId.matches(invite.nodeId) && nonce.matches(invite.nonce) && invite.expiresEpoch > now && invite.expiresEpoch <= now + 660) { "Expired or invalid invitation" }
    }

    private fun validateResponse(response: DeviceEnrollmentResponse) {
        require(nodeId.matches(response.nodeId) && nonce.matches(response.nonce) && deviceId.matches(response.deviceId) && publicValue.matches(response.publicValue) && label.matches(response.label) && response.role in setOf("controller", "traffic-only") && signature.matches(response.signature)) { "Invalid enrollment response" }
    }

    private fun marker(text: String, begin: String, end: String): String {
        val normalized = text.replace("\r\n", "\n")
        require(normalized.split(begin).size == 2 && normalized.split(end).size == 2)
        return normalized.substringAfter("$begin\n").substringBefore("\n$end")
    }

    private fun kv(block: String) = block.lines().filter { '=' in it }.associate { it.substringBefore('=') to it.substringAfter('=') }
    private fun encode(value: String) = Base64.encodeToString(value.toByteArray(), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun decode(value: String, limit: Int): String {
        val bytes = Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        require(bytes.size <= limit)
        return bytes.toString(Charsets.UTF_8)
    }
}
