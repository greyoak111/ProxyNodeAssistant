package com.proxynodeassistant.android.data

import android.content.Context
import android.util.Base64
import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.ManagedKeyRecord
import com.trilead.ssh2.crypto.OpenSSHKeyEncoder
import com.trilead.ssh2.crypto.keys.Ed25519KeyPairGenerator
import com.trilead.ssh2.crypto.keys.Ed25519PrivateKey
import com.trilead.ssh2.crypto.keys.Ed25519PublicKey
import com.trilead.ssh2.signature.Ed25519Verify
import org.json.JSONArray
import org.json.JSONObject

class ManagedKeyRepository(context: Context, private val vault: EncryptedVault) {
    private val preferences = context.getSharedPreferences("key_index", Context.MODE_PRIVATE)

    private data class Entry(val targetId: String, val status: KeyStatus, val created: Long, val secret: String)

    fun generate(targetId: String): ManagedKeyRecord {
        val pair = Ed25519KeyPairGenerator().generateKeyPair()
        val privateKey = pair.private as Ed25519PrivateKey
        val publicKey = pair.public as Ed25519PublicKey
        val privateText = OpenSSHKeyEncoder.exportOpenSSH(privateKey, publicKey, "proxy-node-assistant-android")
        val blob = Ed25519Verify.get().encodePublicKey(publicKey)
        val publicText = "ssh-ed25519 ${Base64.encodeToString(blob, Base64.NO_WRAP)} proxy-node-assistant-android"
        return ManagedKeyRecord(targetId, privateText, publicText)
    }

    fun get(targetId: String, status: KeyStatus = KeyStatus.BOUND): ManagedKeyRecord? =
        entries().filter { it.targetId == targetId && it.status == status }.maxByOrNull { it.created }?.let(::read)
            ?: read(legacyEntry(targetId, status))

    fun list(status: KeyStatus? = null): List<ManagedKeyRecord> = entries()
        .filter { status == null || it.status == status }
        .mapNotNull(::read)
        .sortedWith(compareBy<ManagedKeyRecord> { it.targetId }.thenByDescending { it.createdEpochMs })

    fun put(record: ManagedKeyRecord) {
        val created = record.createdEpochMs.takeIf { it > 0 } ?: System.currentTimeMillis()
        val secret = if (record.status == KeyStatus.BOUND) boundName(record.targetId) else backupName(record.targetId, created)
        vault.put(secret, JSONObject().apply {
            put("private", record.privateKeyOpenSsh)
            put("public", record.publicKeyOpenSsh)
            put("created", created)
        }.toString())
        val current = entries().toMutableList()
        if (record.status == KeyStatus.BOUND) {
            current.filter { it.targetId == record.targetId && it.status == KeyStatus.BOUND && it.secret != secret }.forEach { vault.remove(it.secret) }
            current.removeAll { it.targetId == record.targetId && it.status == KeyStatus.BOUND }
        }
        current.removeAll { it.secret == secret }
        current += Entry(record.targetId, record.status, created, secret)
        saveIndex(current)
    }

    fun archive(targetId: String): Boolean {
        val record = get(targetId, KeyStatus.BOUND) ?: return false
        put(record.copy(status = KeyStatus.BACKUP))
        delete(targetId, KeyStatus.BOUND)
        return true
    }

    fun archiveAll(): Int {
        val keys = list(KeyStatus.BOUND)
        keys.forEach { archive(it.targetId) }
        return keys.size
    }

    /**
     * Move the active key binding to a newly addressed endpoint after the
     * remote identity and host key have been verified.  The old record remains
     * available as BACKUP evidence; no key material is regenerated.
     */
    fun rebind(oldTargetId: String, newTargetId: String): Boolean {
        if (oldTargetId == newTargetId || get(newTargetId, KeyStatus.BOUND) != null) return false
        val record = get(oldTargetId, KeyStatus.BOUND) ?: return false
        put(record.copy(targetId = newTargetId, status = KeyStatus.BOUND))
        archive(oldTargetId)
        return get(newTargetId, KeyStatus.BOUND)?.publicKeyOpenSsh == record.publicKeyOpenSsh
    }

    fun restore(targetId: String, createdEpochMs: Long? = null): Boolean {
        if (get(targetId, KeyStatus.BOUND) != null) return false
        val entry = entries().filter { it.targetId == targetId && it.status == KeyStatus.BACKUP }
            .let { candidates -> createdEpochMs?.let { stamp -> candidates.firstOrNull { it.created == stamp } } ?: candidates.maxByOrNull { it.created } }
            ?: legacyEntry(targetId, KeyStatus.BACKUP).takeIf { vault.contains(it.secret) }
            ?: return false
        val record = read(entry) ?: return false
        put(record.copy(status = KeyStatus.BOUND))
        delete(targetId, KeyStatus.BACKUP, record.createdEpochMs)
        return true
    }

    fun delete(targetId: String, status: KeyStatus, createdEpochMs: Long? = null) {
        val before = entries()
        val matches = before.filter {
            it.targetId == targetId && it.status == status && (createdEpochMs == null || it.created == createdEpochMs)
        }
        matches.forEach { vault.remove(it.secret) }
        if (matches.isEmpty()) vault.remove(if (status == KeyStatus.BOUND) boundName(targetId) else legacyBackupName(targetId))
        saveIndex(before.filterNot { entry -> matches.any { it.secret == entry.secret } })
    }

    private fun read(entry: Entry): ManagedKeyRecord? {
        val raw = vault.get(entry.secret) ?: return null
        return runCatching {
            val item = JSONObject(raw)
            ManagedKeyRecord(entry.targetId, item.getString("private"), item.getString("public"), entry.status, item.optLong("created", entry.created))
        }.getOrNull()
    }

    private fun entries(): List<Entry> {
        val array = runCatching { JSONArray(preferences.getString("entries", "[]")) }.getOrElse { JSONArray() }
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val target = item.optString("target")
                val status = runCatching { KeyStatus.valueOf(item.optString("status")) }.getOrNull() ?: continue
                if (target.isBlank()) continue
                val created = item.optLong("created", 0)
                val secret = item.optString("secret").ifBlank { if (status == KeyStatus.BOUND) boundName(target) else legacyBackupName(target) }
                add(Entry(target, status, created, secret))
            }
        }.distinctBy { it.secret }
    }

    private fun saveIndex(entries: List<Entry>) {
        val array = JSONArray()
        entries.distinctBy { it.secret }.forEach { entry ->
            array.put(JSONObject().put("target", entry.targetId).put("status", entry.status.name).put("created", entry.created).put("secret", entry.secret))
        }
        preferences.edit().putString("entries", array.toString()).apply()
    }

    private fun boundName(targetId: String) = "sshkey:bound:$targetId"
    private fun backupName(targetId: String, created: Long) = "sshkey:backup:$targetId:$created"
    private fun legacyBackupName(targetId: String) = "sshkey:backup:$targetId"
    private fun legacyEntry(targetId: String, status: KeyStatus) = Entry(targetId, status, 0, if (status == KeyStatus.BOUND) boundName(targetId) else legacyBackupName(targetId))
}
