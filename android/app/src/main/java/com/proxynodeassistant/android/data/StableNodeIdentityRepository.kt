package com.proxynodeassistant.android.data

import com.proxynodeassistant.android.model.StableNodeIdentity
import org.json.JSONObject

class StableNodeIdentityRepository(private val vault: EncryptedVault) {
    private fun name(targetId: String) = "node-identity:$targetId"

    fun get(targetId: String): StableNodeIdentity? = vault.get(name(targetId))?.let { raw ->
        runCatching {
            val item = JSONObject(raw)
            StableNodeIdentity(
                targetId,
                item.getString("serverId"), item.getString("nodeId"), item.getString("machineIdSha256"),
                item.getString("hostKeySha256"), item.getString("firstKnownPublicIp"), item.getString("currentPublicIp"),
            )
        }.getOrNull()
    }

    fun put(value: StableNodeIdentity) {
        vault.put(name(value.targetId), JSONObject().apply {
            put("serverId", value.serverId); put("nodeId", value.nodeId); put("machineIdSha256", value.machineIdSha256)
            put("hostKeySha256", value.hostKeySha256); put("firstKnownPublicIp", value.firstKnownPublicIp); put("currentPublicIp", value.currentPublicIp)
        }.toString())
    }

    fun rebind(oldTargetId: String, value: StableNodeIdentity) {
        put(value)
		// Preserve the old endpoint mapping for audit/recovery. The stable IDs and
		// private key remain unchanged; only the active endpoint receives a new record.
    }
}
