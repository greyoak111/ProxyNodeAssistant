package com.proxynodeassistant.android.data

import android.util.Base64
import org.json.JSONObject
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Locale

data class DeviceIdentity(
    val deviceId: String,
    val publicValue: String,
    val createdEpochMs: Long,
)

class DeviceIdentityRepository(private val vault: EncryptedVault) {
    private val secretName = "device-identity:v1"

    fun loadOrCreate(): DeviceIdentity {
        vault.get(secretName)?.let { raw ->
            return decodeAndValidate(raw).first
        }
        val pair = runCatching { KeyPairGenerator.getInstance("Ed25519").generateKeyPair() }
            .getOrElse { throw IllegalStateException("This Android cryptography provider does not support Ed25519 device identities", it) }
        val publicRaw = rawPublic(pair.public.encoded)
        val identity = identity(publicRaw, System.currentTimeMillis())
        val payload = JSONObject()
            .put("version", 1)
            .put("deviceId", identity.deviceId)
            .put("public", identity.publicValue)
            .put("created", identity.createdEpochMs)
            .put("privatePkcs8", Base64.encodeToString(pair.private.encoded, Base64.NO_WRAP))
            .put("publicX509", Base64.encodeToString(pair.public.encoded, Base64.NO_WRAP))
            .toString()
        vault.put(secretName, payload)
        return identity
    }

    fun sign(message: ByteArray): String {
        val raw = vault.get(secretName) ?: throw IllegalStateException("The local device identity is missing; refusing silent rotation")
        val (identity, item) = decodeAndValidate(raw)
        val privateBytes = Base64.decode(item.getString("privatePkcs8"), Base64.NO_WRAP)
        val privateKey = KeyFactory.getInstance("Ed25519").generatePrivate(PKCS8EncodedKeySpec(privateBytes))
        val signature = Signature.getInstance("Ed25519").apply {
            initSign(privateKey)
            update(message)
        }.sign()
        require(signature.size == 64) { "Invalid Ed25519 signature length for ${identity.deviceId}" }
        return Base64.encodeToString(signature, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun decodeAndValidate(raw: String): Pair<DeviceIdentity, JSONObject> {
        val item = runCatching { JSONObject(raw) }.getOrElse { throw IllegalStateException("The protected device identity is corrupt; refusing silent rotation") }
        require(item.optInt("version") == 1) { "Unsupported protected device identity version" }
        val publicX509 = Base64.decode(item.getString("publicX509"), Base64.NO_WRAP)
        val publicRaw = rawPublic(publicX509)
        val identity = identity(publicRaw, item.getLong("created"))
        require(identity.deviceId == item.getString("deviceId") && identity.publicValue == item.getString("public")) {
            "The protected device identity does not match its metadata"
        }
        return identity to item
    }

    private fun rawPublic(x509: ByteArray): ByteArray {
        val prefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)
        require(x509.size == prefix.size + 32 && x509.copyOfRange(0, prefix.size).contentEquals(prefix)) { "Invalid Ed25519 public key encoding" }
        return x509.copyOfRange(prefix.size, x509.size)
    }

    private fun identity(publicRaw: ByteArray, created: Long): DeviceIdentity {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(publicRaw).copyOfRange(0, 16)
        val id = "pna-device-${base32(digest)}"
        val public = "pna-ed25519:${Base64.encodeToString(publicRaw, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)}"
        return DeviceIdentity(id, public, created)
    }

    private fun base32(bytes: ByteArray): String {
        val alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        val output = StringBuilder()
        var buffer = 0
        var bits = 0
        for (value in bytes) {
            buffer = (buffer shl 8) or (value.toInt() and 0xff)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                output.append(alphabet[(buffer shr bits) and 31])
            }
        }
        if (bits > 0) output.append(alphabet[(buffer shl (5 - bits)) and 31])
        return output.toString().lowercase(Locale.US)
    }
}
