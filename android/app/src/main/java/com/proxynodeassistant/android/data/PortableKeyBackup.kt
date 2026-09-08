package com.proxynodeassistant.android.data

import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.ManagedKeyRecord
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

object PortableKeyBackup {
    private val magic = byteArrayOf(0x50, 0x4e, 0x41, 0x4b, 0x31) // PNAK1
    private const val iterations = 250_000

    fun export(records: List<ManagedKeyRecord>, passphrase: CharArray): ByteArray {
        require(records.isNotEmpty()) { "There are no keys to export" }
        require(passphrase.size >= 12) { "Backup passphrase must be at least 12 characters" }
        val array = JSONArray()
        records.forEach { record ->
            array.put(JSONObject().apply {
                put("target", record.targetId)
                put("private", record.privateKeyOpenSsh)
                put("public", record.publicKeyOpenSsh)
                put("status", record.status.name)
                put("created", record.createdEpochMs)
            })
        }
        val plaintext = JSONObject().put("format", 1).put("records", array).toString().toByteArray(Charsets.UTF_8)
        val random = SecureRandom()
        val salt = ByteArray(16).also(random::nextBytes)
        val iv = ByteArray(12).also(random::nextBytes)
        val key = derive(passphrase, salt)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
            cipher.updateAAD(magic)
            val ciphertext = cipher.doFinal(plaintext)
            ByteBuffer.allocate(magic.size + salt.size + iv.size + ciphertext.size).put(magic).put(salt).put(iv).put(ciphertext).array()
        } finally {
            key.encoded?.fill(0)
            plaintext.fill(0)
            passphrase.fill('\u0000')
        }
    }

    fun import(payload: ByteArray, passphrase: CharArray): List<ManagedKeyRecord> {
        require(payload.size in 64..5_000_000) { "Invalid key backup size" }
        require(passphrase.size >= 12) { "Backup passphrase must be at least 12 characters" }
        require(payload.copyOfRange(0, magic.size).contentEquals(magic)) { "This is not a PNA encrypted key backup" }
        val salt = payload.copyOfRange(magic.size, magic.size + 16)
        val iv = payload.copyOfRange(magic.size + 16, magic.size + 28)
        val ciphertext = payload.copyOfRange(magic.size + 28, payload.size)
        val key = derive(passphrase, salt)
        val plaintext = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            cipher.updateAAD(magic)
            cipher.doFinal(ciphertext)
        } catch (error: Throwable) {
            throw IllegalArgumentException("Wrong passphrase or damaged key backup", error)
        } finally {
            key.encoded?.fill(0)
            passphrase.fill('\u0000')
        }
        return try {
            val root = JSONObject(plaintext.toString(Charsets.UTF_8))
            require(root.optInt("format") == 1) { "Unsupported key backup format" }
            val records = root.getJSONArray("records")
            require(records.length() in 1..100) { "Key backup has an invalid record count" }
            buildList {
                for (index in 0 until records.length()) {
                    val item = records.getJSONObject(index)
                    val target = item.getString("target")
                    val privateKey = item.getString("private")
                    val publicKey = item.getString("public")
                    require(target.length in 3..512 && target.none(Char::isISOControl)) { "Invalid target in key backup" }
                    require(privateKey.startsWith("-----BEGIN OPENSSH PRIVATE KEY-----") && privateKey.contains("-----END OPENSSH PRIVATE KEY-----")) { "Invalid private key in backup" }
                    require(publicKey.startsWith("ssh-ed25519 ") && publicKey.length < 2048) { "Invalid public key in backup" }
                    val status = runCatching { KeyStatus.valueOf(item.getString("status")) }.getOrElse { KeyStatus.BACKUP }
                    add(ManagedKeyRecord(target, privateKey, publicKey, status, item.optLong("created", System.currentTimeMillis())))
                }
            }
        } finally {
            plaintext.fill(0)
        }
    }

    private fun derive(passphrase: CharArray, salt: ByteArray): SecretKeySpec {
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1")
        val spec = PBEKeySpec(passphrase, salt, iterations, 256)
        return try { SecretKeySpec(factory.generateSecret(spec).encoded, "AES") } finally { spec.clearPassword() }
    }
}
