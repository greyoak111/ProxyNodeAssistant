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

    fun commitRebind(oldTargetId: String, record: HostKeyRecord) {
        put(record)
		// Keep the old endpoint pin as retired audit evidence. A public-IP change
		// must add a verified binding; it must not silently erase known_hosts history.
    }
}
