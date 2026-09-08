package com.proxynodeassistant.android.data

import com.proxynodeassistant.android.model.StableNodeIdentity
import org.json.JSONObject

/** Stores the VPS identity binding used only for safe endpoint/IP rebinds. */
class StableNodeIdentityRepository(private val vault: EncryptedVault) {
    private fun name(targetId: String) = "node-identity:$targetId"

    fun get(targetId: String): StableNodeIdentity? = vault.get(name(targetId))?.let { raw ->
        runCatching {
            val item = JSONObject(raw)
            StableNodeIdentity(
                targetId = targetId,
                serverId = item.getString("serverId"),
                nodeId = item.getString("nodeId"),
                machineIdSha256 = item.getString("machineIdSha256"),
                hostKeySha256 = item.getString("hostKeySha256"),
                firstKnownPublicIp = item.getString("firstKnownPublicIp"),
                currentPublicIp = item.getString("currentPublicIp"),
            )
        }.getOrNull()
    }

    fun put(value: StableNodeIdentity) {
        vault.put(name(value.targetId), JSONObject().apply {
            put("serverId", value.serverId)
            put("nodeId", value.nodeId)
            put("machineIdSha256", value.machineIdSha256)
            put("hostKeySha256", value.hostKeySha256)
            put("firstKnownPublicIp", value.firstKnownPublicIp)
            put("currentPublicIp", value.currentPublicIp)
        }.toString())
    }

    /**
     * Keep the old record as audit evidence and add the new endpoint binding.
     * The identity values themselves must already have been verified remotely.
     */
    fun rebind(oldTargetId: String, value: StableNodeIdentity) {
        require(oldTargetId != value.targetId) { "stable identity rebind requires a new target" }
        put(value)
    }
}
