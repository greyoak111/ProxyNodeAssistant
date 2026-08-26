package com.proxynodeassistant.android.remote

import android.util.Base64
import com.proxynodeassistant.android.data.DeviceIdentity
import org.json.JSONObject
import java.security.MessageDigest

data class DeviceInvite(
    val version: Int = 2,
    val nodeId: String,
    val nonce: String,
    val host: String,
    val user: String,
    val port: Int,
    val knownHosts: String,
)

data class DeviceEnrollmentResponse(
    val version: Int = 2,
    val nodeId: String,
    val nonce: String,
    val deviceId: String,
    val publicValue: String,
    val label: String,
    val role: String,
    val encryptionPublic: String,
    val sshUser: String,
    val sshPublic: String,
    val signature: String,
)

data class DeviceStatusRecord(val deviceId: String, val role: String, val status: String, val label: String, val createdAt: String)
data class DeviceAdmissionStatus(val nodeId: String, val activeControllers: Int, val activeDevices: Int, val devices: List<DeviceStatusRecord>)

object DeviceAdmissionProtocol {
    private val nodeId = Regex("^(?:tna|pna)-node-[0-9a-f]{32}$")
    private val deviceId = Regex("^(?:tna|pna)-device-[a-z2-7]{26}$")
    private val publicValue = Regex("^(?:tna|pna)-ed25519:[A-Za-z0-9_-]{43}$")
    private val encryptionPublic = Regex("^tna-x25519:[A-Za-z0-9_-]{43}$")
    private val sshPublic = Regex("^ssh-ed25519 [A-Za-z0-9+/]{68}$")
    private val sshUser = Regex("^[A-Za-z_][A-Za-z0-9_.-]*$")
    private val nonce = Regex("^[0-9a-f]{64}$")
    private val signature = Regex("^[A-Za-z0-9_-]{86}$")
    private val label = Regex("^[A-Za-z0-9._ -]{1,64}$")

    fun parseStatus(text: String): DeviceAdmissionStatus {
        val block = markerCurrentOrLegacy(text, "__TNA_DEVICE_STATUS_V1_BEGIN__", "__TNA_DEVICE_STATUS_V1_END__", "__PNA_DEVICE_STATUS_V1_BEGIN__", "__PNA_DEVICE_STATUS_V1_END__")
        val values = linkedMapOf<String, String>()
        val devices = mutableListOf<DeviceStatusRecord>()
        block.lines().filter { it.isNotBlank() }.forEach { line ->
            if (line.startsWith("DEVICE\t")) {
                val parts = line.split('\t')
                require(parts.size == 6 && deviceId.matches(parts[1]) && parts[2] in setOf("controller", "traffic-only") && parts[3] in setOf("active", "paused", "revoked", "pending-verification", "REVOCATION_PARTIAL") && label.matches(parts[4])) { "Invalid device status row" }
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

    fun parseInviteOutput(text: String, endpoint: NodeEndpoint): DeviceInvite {
        val values = kv(marker(text, "__TNA_DEVICE_INVITE_V2_BEGIN__", "__TNA_DEVICE_INVITE_V2_END__"))
        require(values["EXPIRES_ON_SUCCESSFUL_BIND"] == "1") { "Invalid invitation consumption policy" }
        return DeviceInvite(
            nodeId = values.getValue("NODE_ID"),
            nonce = values.getValue("ENROLLMENT_NONCE"),
            host = endpoint.host,
            user = endpoint.user,
            port = endpoint.port,
            knownHosts = endpoint.knownHosts,
        ).also(::validateInvite)
    }

    fun encodeInvite(invite: DeviceInvite): String {
        validateInvite(invite)
        val item = JSONObject().put("v", 2).put("node", invite.nodeId).put("nonce", invite.nonce)
            .put("host", invite.host).put("user", invite.user).put("port", invite.port).put("knownHosts", invite.knownHosts)
        return "TNAINV2.${encode(item.toString())}"
    }

    fun decodeInvite(bundle: String): DeviceInvite {
        require(bundle.startsWith("TNAINV2.")) { "Invalid invitation prefix" }
        val item = JSONObject(decode(bundle.removePrefix("TNAINV2."), 8192))
        require(item.getInt("v") == 2)
        return DeviceInvite(
            nodeId = item.getString("node"), nonce = item.getString("nonce"), host = item.getString("host"),
            user = item.getString("user"), port = item.getInt("port"), knownHosts = item.getString("knownHosts"),
        ).also(::validateInvite)
    }

    fun signingBytes(response: DeviceEnrollmentResponse): ByteArray = buildString {
        appendLine("TNA-DEVICE-ENROLL-V2")
        appendLine("NODE_ID=${response.nodeId}")
        appendLine("NONCE=${response.nonce}")
        appendLine("DEVICE_ID=${response.deviceId}")
        appendLine("PUBLIC_KEY=${response.publicValue}")
        appendLine("LABEL=${response.label}")
        appendLine("ROLE=${response.role}")
        appendLine("ENCRYPTION_PUBLIC_KEY=${response.encryptionPublic}")
        appendLine("SSH_LOGIN_USER=${response.sshUser}")
        appendLine("SSH_PUBLIC_KEY=${response.sshPublic}")
    }.toByteArray(Charsets.UTF_8)

    fun response(
        invite: DeviceInvite,
        identity: DeviceIdentity,
        labelValue: String,
        role: String,
        sshPublicValue: String,
        signer: (ByteArray) -> String,
    ): DeviceEnrollmentResponse {
        require(label.matches(labelValue) && role in setOf("controller", "traffic-only"))
        val normalizedSsh = normalizeSshPublic(sshPublicValue)
        val unsigned = DeviceEnrollmentResponse(
            nodeId = invite.nodeId, nonce = invite.nonce, deviceId = identity.deviceId, publicValue = identity.publicValue,
            label = labelValue, role = role, encryptionPublic = identity.encryptionPublic, sshUser = invite.user,
            sshPublic = normalizedSsh, signature = "",
        )
        return unsigned.copy(signature = signer(signingBytes(unsigned))).also(::validateResponse)
    }

    fun encodeResponse(response: DeviceEnrollmentResponse): String {
        validateResponse(response)
        val item = JSONObject().put("v", 2).put("node", response.nodeId).put("nonce", response.nonce).put("device", response.deviceId)
            .put("public", response.publicValue).put("label", response.label).put("role", response.role)
            .put("encryptionPublic", response.encryptionPublic).put("sshUser", response.sshUser).put("sshPublic", response.sshPublic)
            .put("signature", response.signature)
        return "TNARESP2.${encode(item.toString())}"
    }

    fun decodeResponse(bundle: String): DeviceEnrollmentResponse {
        require(bundle.startsWith("TNARESP2.")) { "Invalid response prefix" }
        val item = JSONObject(decode(bundle.removePrefix("TNARESP2."), 8192))
        require(item.getInt("v") == 2)
        return DeviceEnrollmentResponse(
            nodeId = item.getString("node"), nonce = item.getString("nonce"), deviceId = item.getString("device"),
            publicValue = item.getString("public"), label = item.getString("label"), role = item.getString("role"),
            encryptionPublic = item.getString("encryptionPublic"), sshUser = item.getString("sshUser"),
            sshPublic = normalizeSshPublic(item.getString("sshPublic")), signature = item.getString("signature"),
        ).also(::validateResponse)
    }

    fun enrollmentInput(response: DeviceEnrollmentResponse): ByteArray {
        validateResponse(response)
        return buildString {
            appendLine(response.nonce)
            appendLine(response.publicValue)
            appendLine(response.label)
            appendLine(response.role)
            appendLine(response.encryptionPublic)
            appendLine(response.sshUser)
            appendLine(response.sshPublic)
            appendLine(response.signature)
        }.toByteArray(Charsets.UTF_8)
    }

    private fun validateInvite(invite: DeviceInvite) {
        require(invite.version == 2 && nodeId.matches(invite.nodeId) && nonce.matches(invite.nonce)) { "Invalid invitation identity" }
        require(validHost(invite.host) && sshUser.matches(invite.user) && invite.port in 1..65535) { "Invitation has no usable SSH endpoint" }
        val records = invite.knownHosts.trim().lines().filter { it.isNotBlank() }
        require(records.isNotEmpty() && invite.knownHosts.length <= 6144) { "Invitation has no pinned SSH host key" }
        val expectedHostTokens = if (invite.port == 22) {
            setOf(invite.host, "[${invite.host}]:${invite.port}")
        } else {
            setOf("[${invite.host}]:${invite.port}")
        }
        val supportedAlgorithms = setOf(
            "ssh-ed25519",
            "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
            "ssh-rsa",
        )
        records.forEach { line ->
            val parts = line.trim().split(Regex("\\s+"))
            require(
                parts.size == 3 &&
                    parts[0] in expectedHostTokens &&
                    parts[1] in supportedAlgorithms &&
                    Base64.decode(parts[2], Base64.DEFAULT).isNotEmpty()
            ) { "Invitation contains a host key that does not match its SSH endpoint" }
        }
    }

    private fun validateResponse(response: DeviceEnrollmentResponse) {
        require(response.version == 2 && nodeId.matches(response.nodeId) && nonce.matches(response.nonce)) { "Invalid enrollment node or nonce" }
        require(deviceId.matches(response.deviceId) && response.deviceId.startsWith("tna-device-") && publicValue.matches(response.publicValue) && response.publicValue.startsWith("tna-ed25519:")) { "Invalid enrollment identity" }
        require(label.matches(response.label) && response.role in setOf("controller", "traffic-only")) { "Invalid enrollment role or label" }
        require(encryptionPublic.matches(response.encryptionPublic) && sshUser.matches(response.sshUser) && sshPublic.matches(response.sshPublic) && signature.matches(response.signature)) { "Invalid enrollment key material" }
        val rawPublic = Base64.decode(response.publicValue.substringAfter(':'), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val digest = MessageDigest.getInstance("SHA-256").digest(rawPublic).copyOfRange(0, 16)
        require(response.deviceId == "tna-device-${base32(digest)}") { "Enrollment device ID does not match its public key" }
    }

    private fun normalizeSshPublic(value: String): String {
        val parts = value.trim().split(Regex("\\s+"))
        require(parts.size >= 2)
        return "${parts[0]} ${parts[1]}".also { require(sshPublic.matches(it)) { "Only a valid Ed25519 SSH public key is accepted" } }
    }

    private fun validHost(value: String): Boolean = value.length in 1..253 && value.none { it.isWhitespace() || it in "/\\?#@" }
    private fun markerCurrentOrLegacy(text: String, begin: String, end: String, legacyBegin: String, legacyEnd: String) =
        runCatching { marker(text, begin, end) }.getOrElse { marker(text, legacyBegin, legacyEnd) }

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

data class NodeEndpoint(val host: String, val user: String, val port: Int, val knownHosts: String)
