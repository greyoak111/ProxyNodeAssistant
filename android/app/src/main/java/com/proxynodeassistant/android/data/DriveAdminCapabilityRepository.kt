package com.proxynodeassistant.android.data

import org.json.JSONObject

data class DriveAdminCapability(
    val nodeId: String,
    val username: String,
    val password: String,
)

class DriveAdminCapabilityRepository(private val vault: EncryptedVault) {
    private val node = Regex("^tna-node-[0-9a-f]{32}$")
    private val username = Regex("^tna-admin-[0-9a-f]{12}$")

    fun put(value: DriveAdminCapability) {
        validate(value)
        vault.put(
            "drive-admin:v1:${value.nodeId}",
            JSONObject()
                .put("version", 1)
                .put("nodeId", value.nodeId)
                .put("username", value.username)
                .put("password", value.password)
                .toString(),
        )
    }

    fun get(nodeId: String): DriveAdminCapability? {
        if (!node.matches(nodeId)) return null
        val raw = vault.get("drive-admin:v1:$nodeId") ?: return null
        return runCatching {
            val item = JSONObject(raw)
            require(item.getInt("version") == 1)
            DriveAdminCapability(item.getString("nodeId"), item.getString("username"), item.getString("password")).also(::validate)
        }.getOrNull()
    }

    private fun validate(value: DriveAdminCapability) {
        require(node.matches(value.nodeId) && username.matches(value.username))
        require(value.password.length in 14..128 && value.password.all { it.code in 0x20..0x7e })
    }
}
