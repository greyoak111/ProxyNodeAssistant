package com.proxynodeassistant.android.data

import android.util.Base64
import org.json.JSONObject
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Locale

data class DeviceIdentity(
    val version: Int,
    val deviceId: String,
    val publicValue: String,
    val encryptionPublic: String,
    val createdEpochMs: Long,
)

data class X25519Exchange(val ephemeralPublic: String, val sharedSecret: ByteArray)

class DeviceIdentityRepository private constructor(
    private val getSecret: (String) -> String?,
    private val putSecret: (String, String) -> Unit,
    private val removeSecret: (String) -> Unit,
) {
    constructor(vault: EncryptedVault) : this(vault::get, vault::put, vault::remove)

    internal constructor(memory: MutableMap<String, String>) : this(
        getSecret = memory::get,
        putSecret = { name, value -> memory[name] = value },
        removeSecret = { name -> memory.remove(name) },
    )

    private val secretName = "device-identity:v2"
    private val legacySecretName = "device-identity:v1"

    fun loadOrCreate(): DeviceIdentity {
        getSecret(secretName)?.let { raw -> return decodeAndValidate(raw).first }
        getSecret(legacySecretName)?.let { raw -> return migrateV1(raw) }

        val pair = runCatching { KeyPairGenerator.getInstance("Ed25519").generateKeyPair() }
            .getOrElse { throw IllegalStateException("This Android cryptography provider does not support Ed25519 device identities", it) }
        val x25519Private = ByteArray(32).also(SecureRandom()::nextBytes)
        val identity = identity(rawPublic(pair.public.encoded), x25519Public(x25519Private), System.currentTimeMillis())
        persist(identity, pair.private.encoded, pair.public.encoded, x25519Private)
        return identity
    }

    fun sign(message: ByteArray): String {
        val raw = getSecret(secretName) ?: throw IllegalStateException("The local device identity is missing; refusing silent rotation")
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

    fun x25519Shared(peerPublicValue: String): ByteArray {
        require(peerPublicValue.startsWith("tna-x25519:")) { "Unsupported X25519 public-key namespace" }
        val peer = Base64.decode(
            peerPublicValue.removePrefix("tna-x25519:"),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        require(peer.size == 32 && peer.any { it != 0.toByte() }) { "Invalid X25519 peer public key" }
        val raw = getSecret(secretName) ?: throw IllegalStateException("The local device identity is missing")
        val (_, item) = decodeAndValidate(raw)
        val privateScalar = Base64.decode(item.getString("x25519Private"), Base64.NO_WRAP)
        return x25519(privateScalar, peer).also { shared ->
            require(shared.any { it != 0.toByte() }) { "X25519 rejected a low-order peer public key" }
        }
    }

    fun x25519Ephemeral(peerPublicValue: String): X25519Exchange {
        require(peerPublicValue.startsWith("tna-x25519:")) { "Unsupported X25519 public-key namespace" }
        val peer = Base64.decode(
            peerPublicValue.removePrefix("tna-x25519:"),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        require(peer.size == 32 && peer.any { it != 0.toByte() }) { "Invalid X25519 peer public key" }
        val privateScalar = ByteArray(32).also(SecureRandom()::nextBytes)
        val publicRaw = x25519Public(privateScalar)
        val shared = x25519(privateScalar, peer)
        require(shared.any { it != 0.toByte() }) { "X25519 rejected a low-order peer public key" }
        return X25519Exchange("tna-x25519:${rawUrl(publicRaw)}", shared)
    }

    private fun migrateV1(raw: String): DeviceIdentity {
        val item = runCatching { JSONObject(raw) }.getOrElse { throw IllegalStateException("The protected legacy device identity is corrupt; refusing silent rotation") }
        require(item.optInt("version") == 1) { "Unsupported protected legacy device identity version" }
        val privatePkcs8 = Base64.decode(item.getString("privatePkcs8"), Base64.NO_WRAP)
        val publicX509 = Base64.decode(item.getString("publicX509"), Base64.NO_WRAP)
        val legacyPublic = rawPublic(publicX509)
        val legacyId = legacyIdentity(legacyPublic, item.getLong("created"))
        require(legacyId.deviceId == item.getString("deviceId") && legacyId.publicValue == item.getString("public")) {
            "The protected legacy device identity does not match its metadata"
        }
        val x25519Private = ByteArray(32).also(SecureRandom()::nextBytes)
        val migrated = identity(legacyPublic, x25519Public(x25519Private), legacyId.createdEpochMs)
        persist(migrated, privatePkcs8, publicX509, x25519Private)
        removeSecret(legacySecretName)
        return migrated
    }

    private fun persist(identity: DeviceIdentity, privatePkcs8: ByteArray, publicX509: ByteArray, x25519Private: ByteArray) {
        val payload = JSONObject()
            .put("version", 2)
            .put("deviceId", identity.deviceId)
            .put("public", identity.publicValue)
            .put("encryptionPublic", identity.encryptionPublic)
            .put("created", identity.createdEpochMs)
            .put("privatePkcs8", Base64.encodeToString(privatePkcs8, Base64.NO_WRAP))
            .put("publicX509", Base64.encodeToString(publicX509, Base64.NO_WRAP))
            .put("x25519Private", Base64.encodeToString(x25519Private, Base64.NO_WRAP))
            .toString()
        putSecret(secretName, payload)
    }

    private fun decodeAndValidate(raw: String): Pair<DeviceIdentity, JSONObject> {
        val item = runCatching { JSONObject(raw) }.getOrElse { throw IllegalStateException("The protected device identity is corrupt; refusing silent rotation") }
        require(item.optInt("version") == 2) { "Unsupported protected device identity version" }
        val publicX509 = Base64.decode(item.getString("publicX509"), Base64.NO_WRAP)
        val x25519Private = Base64.decode(item.getString("x25519Private"), Base64.NO_WRAP)
        require(x25519Private.size == 32) { "Invalid protected X25519 private key" }
        val identity = identity(rawPublic(publicX509), x25519Public(x25519Private), item.getLong("created"))
        require(
            identity.deviceId == item.getString("deviceId") &&
                identity.publicValue == item.getString("public") &&
                identity.encryptionPublic == item.getString("encryptionPublic")
        ) { "The protected device identity does not match its metadata" }
        return identity to item
    }

    private fun rawPublic(x509: ByteArray): ByteArray {
        val prefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)
        require(x509.size == prefix.size + 32 && x509.copyOfRange(0, prefix.size).contentEquals(prefix)) { "Invalid Ed25519 public key encoding" }
        return x509.copyOfRange(prefix.size, x509.size)
    }

    private fun identity(publicRaw: ByteArray, encryptionRaw: ByteArray, created: Long): DeviceIdentity {
        val digest = MessageDigest.getInstance("SHA-256").digest(publicRaw).copyOfRange(0, 16)
        return DeviceIdentity(
            version = 2,
            deviceId = "tna-device-${base32(digest)}",
            publicValue = "tna-ed25519:${rawUrl(publicRaw)}",
            encryptionPublic = "tna-x25519:${rawUrl(encryptionRaw)}",
            createdEpochMs = created,
        )
    }

    private fun legacyIdentity(publicRaw: ByteArray, created: Long): DeviceIdentity {
        val digest = MessageDigest.getInstance("SHA-256").digest(publicRaw).copyOfRange(0, 16)
        return DeviceIdentity(1, "pna-device-${base32(digest)}", "pna-ed25519:${rawUrl(publicRaw)}", "", created)
    }

    // RFC 7748 Montgomery ladder. Only the public key leaves this function;
    // the raw scalar remains in the Android Keystore-encrypted app vault.
    internal fun x25519Public(rawPrivate: ByteArray): ByteArray =
        x25519(rawPrivate, ByteArray(32).also { it[0] = 9 })

    private fun x25519(rawPrivate: ByteArray, rawPeer: ByteArray): ByteArray {
        require(rawPrivate.size == 32)
        require(rawPeer.size == 32)
        val scalar = rawPrivate.copyOf().apply {
            this[0] = (this[0].toInt() and 248).toByte()
            this[31] = ((this[31].toInt() and 127) or 64).toByte()
        }
        val k = littleEndianInteger(scalar)
        val p = BigInteger.ONE.shiftLeft(255).subtract(BigInteger.valueOf(19))
        val a24 = BigInteger.valueOf(121665)
        val peer = rawPeer.copyOf().apply { this[31] = (this[31].toInt() and 127).toByte() }
        val x1 = littleEndianInteger(peer)
        require(x1 < p) { "Non-canonical X25519 peer public key" }
        var x2 = BigInteger.ONE
        var z2 = BigInteger.ZERO
        var x3 = x1
        var z3 = BigInteger.ONE
        var swap = false
        for (bit in 254 downTo 0) {
            val current = k.testBit(bit)
            if (swap.xor(current)) {
                val tx = x2; x2 = x3; x3 = tx
                val tz = z2; z2 = z3; z3 = tz
            }
            swap = current
            val a = mod(x2 + z2, p)
            val aa = mod(a * a, p)
            val b = mod(x2 - z2, p)
            val bb = mod(b * b, p)
            val e = mod(aa - bb, p)
            val c = mod(x3 + z3, p)
            val d = mod(x3 - z3, p)
            val da = mod(d * a, p)
            val cb = mod(c * b, p)
            x3 = mod((da + cb).pow(2), p)
            z3 = mod(x1 * mod((da - cb).pow(2), p), p)
            x2 = mod(aa * bb, p)
            z2 = mod(e * mod(aa + a24 * e, p), p)
        }
        if (swap) {
            val tx = x2; x2 = x3; x3 = tx
            val tz = z2; z2 = z3; z3 = tz
        }
        return littleEndianBytes(mod(x2 * z2.modInverse(p), p), 32)
    }

    private fun mod(value: BigInteger, modulus: BigInteger): BigInteger = value.mod(modulus)
    private fun littleEndianInteger(bytes: ByteArray) = BigInteger(1, bytes.reversedArray())
    private fun littleEndianBytes(value: BigInteger, size: Int): ByteArray {
        val big = value.toByteArray().let { if (it.size > 1 && it[0] == 0.toByte()) it.copyOfRange(1, it.size) else it }
        require(big.size <= size)
        return ByteArray(size).also { out -> big.indices.forEach { index -> out[index] = big[big.lastIndex - index] } }
    }

    private fun rawUrl(value: ByteArray) = Base64.encodeToString(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

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
