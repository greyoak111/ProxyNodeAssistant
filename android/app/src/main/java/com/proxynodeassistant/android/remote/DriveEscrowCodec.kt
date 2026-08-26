package com.proxynodeassistant.android.remote

import android.util.Base64
import com.proxynodeassistant.android.data.DeviceIdentity
import com.proxynodeassistant.android.data.DeviceIdentityRepository
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

data class ControllerEncryptionKey(val deviceId: String, val publicValue: String)
data class DriveEscrowEnvelope(
    val deviceId: String,
    val encryptionKey: String,
    val ephemeralPublic: String,
    val nonce: String,
    val wrappedKey: String,
)
data class DriveCredentialEscrow(
    val version: Int,
    val nodeId: String,
    val accountId: String,
    val spaceId: String,
    val username: String,
    val cipherNonce: String,
    val ciphertext: String,
    val envelopes: List<DriveEscrowEnvelope>,
)

object DriveEscrowCodec {
    private val nodeId = Regex("^tna-node-[0-9a-f]{32}$")
    private val accountId = Regex("^tna-account-[0-9a-f]{32}$")
    private val spaceId = Regex("^tna-space-[0-9a-f]{32}$")
    private val deviceId = Regex("^tna-device-[a-z2-7]{26}$")
    private val publicKey = Regex("^tna-x25519:[A-Za-z0-9_-]{43}$")
    private val username = Regex("^[A-Za-z][A-Za-z0-9._-]{2,31}$")

    fun decode(rawJson: String): DriveCredentialEscrow {
        require(rawJson.toByteArray().size <= 32_768) { "Drive escrow is unexpectedly large" }
        val item = JSONObject(rawJson)
        val cipher = item.getJSONObject("ciphertext")
        val envelopesJson = item.getJSONArray("envelopes")
        val envelopes = (0 until envelopesJson.length()).map { index ->
            envelopesJson.getJSONObject(index).let {
                DriveEscrowEnvelope(
                    it.getString("deviceId"), it.getString("encryptionPublicKey"),
                    it.getString("ephemeralPublicKey"), it.getString("nonce"), it.getString("wrappedKey"),
                )
            }
        }
        return DriveCredentialEscrow(
            item.getInt("version"), item.getString("nodeId"), item.getString("accountId"),
            item.getString("spaceId"), item.getString("username"), cipher.getString("nonce"),
            cipher.getString("data"), envelopes,
        ).also(::validate)
    }

    fun encode(value: DriveCredentialEscrow): String {
        validate(value)
        val envelopes = JSONArray().also { array ->
            value.envelopes.forEach { envelope ->
                array.put(
                    JSONObject()
                        .put("deviceId", envelope.deviceId)
                        .put("encryptionPublicKey", envelope.encryptionKey)
                        .put("ephemeralPublicKey", envelope.ephemeralPublic)
                        .put("nonce", envelope.nonce)
                        .put("wrappedKey", envelope.wrappedKey),
                )
            }
        }
        return JSONObject()
            .put("version", 1)
            .put("nodeId", value.nodeId)
            .put("accountId", value.accountId)
            .put("spaceId", value.spaceId)
            .put("username", value.username)
            .put("ciphertext", JSONObject().put("nonce", value.cipherNonce).put("data", value.ciphertext))
            .put("envelopes", envelopes)
            .toString()
            .also { require(it.toByteArray().size <= 32_768) }
    }

    fun decrypt(value: DriveCredentialEscrow, identity: DeviceIdentity, keys: DeviceIdentityRepository): String {
        validate(value)
        val envelope = value.envelopes.singleOrNull { it.deviceId == identity.deviceId }
            ?: error("This controller has no matching drive credential envelope")
        require(envelope.encryptionKey == identity.encryptionPublic) { "Drive envelope uses a different controller key" }
        val aad = aad(value)
        val shared = keys.x25519Shared(envelope.ephemeralPublic)
        val dek = open(
            envelopeKey(shared, aad),
            rawUrlDecode(envelope.nonce),
            rawUrlDecode(envelope.wrappedKey),
            aad + identity.deviceId.toByteArray(),
        )
        val password = open(
            dek,
            rawUrlDecode(value.cipherNonce),
            rawUrlDecode(value.ciphertext),
            aad,
        ).toString(Charsets.UTF_8)
        require(password.length in 14..128 && password.all { it.code in 0x20..0x7e }) { "Decrypted drive password is invalid" }
        return password
    }

    fun rewrap(
        existing: DriveCredentialEscrow,
        password: String,
        controllers: List<ControllerEncryptionKey>,
        keys: DeviceIdentityRepository,
    ): DriveCredentialEscrow {
        validate(existing)
        return encryptMetadata(existing, password, controllers, keys)
    }

    fun encryptNew(
        nodeId: String,
        accountId: String,
        spaceId: String,
        username: String,
        password: String,
        controllers: List<ControllerEncryptionKey>,
        keys: DeviceIdentityRepository,
    ): DriveCredentialEscrow = encryptMetadata(
        DriveCredentialEscrow(1, nodeId, accountId, spaceId, username, "", "", emptyList()),
        password,
        controllers,
        keys,
    )

    private fun encryptMetadata(
        existing: DriveCredentialEscrow,
        password: String,
        controllers: List<ControllerEncryptionKey>,
        keys: DeviceIdentityRepository,
    ): DriveCredentialEscrow {
        require(existing.version == 1 && nodeId.matches(existing.nodeId) && accountId.matches(existing.accountId) && spaceId.matches(existing.spaceId) && username.matches(existing.username))
        require(password.length in 14..128 && password.all { it.code in 0x20..0x7e })
        require(controllers.isNotEmpty() && controllers.map { it.deviceId }.distinct().size == controllers.size)
        val empty = existing.copy(cipherNonce = "", ciphertext = "", envelopes = emptyList())
        val aad = aad(empty)
        val dek = ByteArray(32).also(SecureRandom()::nextBytes)
        val sealed = seal(dek, password.toByteArray(), aad)
        val envelopes = controllers.sortedBy { it.deviceId }.map { controller ->
            require(deviceId.matches(controller.deviceId) && publicKey.matches(controller.publicValue))
            val exchange = keys.x25519Ephemeral(controller.publicValue)
            val wrapped = seal(envelopeKey(exchange.sharedSecret, aad), dek, aad + controller.deviceId.toByteArray())
            DriveEscrowEnvelope(
                controller.deviceId,
                controller.publicValue,
                exchange.ephemeralPublic,
                rawUrl(wrapped.first),
                rawUrl(wrapped.second),
            )
        }
        return empty.copy(
            cipherNonce = rawUrl(sealed.first),
            ciphertext = rawUrl(sealed.second),
            envelopes = envelopes,
        ).also(::validate)
    }

    private fun validate(value: DriveCredentialEscrow) {
        require(
            value.version == 1 && nodeId.matches(value.nodeId) && accountId.matches(value.accountId) &&
                spaceId.matches(value.spaceId) && username.matches(value.username) && value.envelopes.isNotEmpty(),
        ) { "Invalid drive credential escrow" }
        require(value.envelopes.map { it.deviceId }.distinct().size == value.envelopes.size)
        value.envelopes.forEach {
            require(deviceId.matches(it.deviceId) && publicKey.matches(it.encryptionKey) && publicKey.matches(it.ephemeralPublic))
            rawUrlDecode(it.nonce); rawUrlDecode(it.wrappedKey)
        }
        if (value.cipherNonce.isNotEmpty()) rawUrlDecode(value.cipherNonce)
        if (value.ciphertext.isNotEmpty()) rawUrlDecode(value.ciphertext)
    }

    private fun aad(value: DriveCredentialEscrow) = (
        "TNA-DRIVE-CREDENTIAL-ESCROW-V1\n" +
            "NODE_ID=${value.nodeId}\nACCOUNT_ID=${value.accountId}\nSPACE_ID=${value.spaceId}\nUSERNAME=${value.username}\n"
        ).toByteArray()

    private fun envelopeKey(shared: ByteArray, aad: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(shared, "HmacSHA256"))
        return mac.doFinal("TNA-DRIVE-DEK-WRAP-V1\u0000".toByteArray() + aad)
    }

    private fun seal(key: ByteArray, plaintext: ByteArray, aad: ByteArray): Pair<ByteArray, ByteArray> {
        val nonce = ByteArray(12).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return nonce to cipher.doFinal(plaintext)
    }

    private fun open(key: ByteArray, nonce: ByteArray, sealed: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(sealed)
    }

    fun rawUrl(value: ByteArray): String = Base64.encodeToString(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    fun rawUrlDecode(value: String): ByteArray = Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}
