package com.proxynodeassistant.android.data

import android.content.Context
import com.proxynodeassistant.android.model.NodeTarget
import org.json.JSONArray
import org.json.JSONObject

class TargetRepository(context: Context) {
    private val preferences = context.getSharedPreferences("targets", Context.MODE_PRIVATE)

    fun list(): List<NodeTarget> {
        val raw = preferences.getString("recent", "[]") ?: "[]"
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.getJSONObject(index)
                    add(NodeTarget(item.getString("host"), item.optString("user", "root"), item.optInt("port", 22), item.optString("label"), item.optLong("lastUsed", 0)))
                }
            }.sortedByDescending { it.lastUsedEpochMs }
        }.getOrDefault(emptyList())
    }

    fun remember(target: NodeTarget) {
        val updated = list().filterNot { it.id == target.id }.toMutableList()
        updated.add(0, target.copy(lastUsedEpochMs = System.currentTimeMillis()))
        save(updated.take(50))
    }

    fun delete(targetId: String) = save(list().filterNot { it.id == targetId })
    fun clear() = preferences.edit().remove("recent").apply()

    private fun save(targets: List<NodeTarget>) {
        val array = JSONArray()
        targets.forEach { target ->
            array.put(JSONObject().apply {
                put("host", target.host)
                put("user", target.user)
                put("port", target.port)
                put("label", target.label)
                put("lastUsed", target.lastUsedEpochMs)
            })
        }
        preferences.edit().putString("recent", array.toString()).apply()
    }
}
