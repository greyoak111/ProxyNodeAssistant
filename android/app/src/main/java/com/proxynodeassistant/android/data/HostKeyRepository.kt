package com.proxynodeassistant.android.data

import com.proxynodeassistant.android.model.HostKeyRecord
import org.json.JSONObject

class HostKeyRepository(private val vault: EncryptedVault) {
    private fun name(targetId: String) = "hostkey:$targetId"

    fun get(targetId: String): HostKeyRecord? {
        val raw = vault.get(name(targetId)) ?: return null
        return runCatching {
            val item = JSONObject(raw)
            HostKeyRecord(targetId, item.getString("algorithm"), item.getString("key"), item.getString("fingerprint"), item.optLong("accepted", 0))
        }.getOrNull()
    }

    fun put(record: HostKeyRecord) {
        vault.put(name(record.targetId), JSONObject().apply {
            put("algorithm", record.algorithm)
            put("key", record.keyBase64)
            put("fingerprint", record.fingerprint)
            put("accepted", record.acceptedEpochMs)
        }.toString())
    }

    fun delete(targetId: String) = vault.remove(name(targetId))

    /** Commit a host-key pin for a verified endpoint change without deleting the old pin. */
    fun commitRebind(oldTargetId: String, record: HostKeyRecord) {
        require(oldTargetId != record.targetId) { "host-key rebind requires a new target" }
        put(record)
    }
}
