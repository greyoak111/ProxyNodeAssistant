package com.proxynodeassistant.android.data

import android.content.Context
import com.proxynodeassistant.android.model.CachedKiwiUsage
import com.proxynodeassistant.android.model.KiwiUsage
import org.json.JSONObject

class ProviderUsageRepository(context: Context) {
    private val preferences = context.getSharedPreferences("provider_usage_cache", Context.MODE_PRIVATE)

    fun put(usage: KiwiUsage, checkedEpochMs: Long = System.currentTimeMillis()) {
        preferences.edit().putString(key(usage.veid), encode(CachedKiwiUsage(usage, checkedEpochMs))).apply()
    }

    fun get(veid: String): CachedKiwiUsage? = preferences.getString(key(veid), null)?.let(::decode)

    fun list(): List<CachedKiwiUsage> = preferences.all.values.mapNotNull { (it as? String)?.let(::decode) }
        .sortedByDescending { it.checkedEpochMs }

    fun delete(veid: String) = preferences.edit().remove(key(veid)).apply()

    private fun key(veid: String) = "kiwivm:${veid.trim()}"

    companion object {
        internal fun encode(record: CachedKiwiUsage): String = JSONObject().apply {
            put("format", 1)
            put("checkedEpochMs", record.checkedEpochMs)
            put("veid", record.usage.veid)
            put("hostname", record.usage.hostname)
            put("location", record.usage.location)
            put("plan", record.usage.plan)
            put("usedBytes", record.usage.usedBytes)
            put("allowanceBytes", record.usage.allowanceBytes)
            put("multiplier", record.usage.multiplier)
            put("resetEpochSeconds", record.usage.resetEpochSeconds)
            put("suspended", record.usage.suspended)
            put("policyViolation", record.usage.policyViolation)
        }.toString()

        internal fun decode(raw: String): CachedKiwiUsage? = runCatching {
            val json = JSONObject(raw)
            require(json.optInt("format") == 1)
            val veid = json.getString("veid")
            val checked = json.getLong("checkedEpochMs")
            val used = json.getLong("usedBytes")
            val allowance = json.getLong("allowanceBytes")
            require(veid.matches(Regex("^[0-9]{3,12}$")) && checked > 0 && used >= 0 && allowance > 0)
            CachedKiwiUsage(
                KiwiUsage(
                    veid = veid,
                    hostname = json.optString("hostname"),
                    location = json.optString("location"),
                    plan = json.optString("plan"),
                    usedBytes = used,
                    allowanceBytes = allowance,
                    multiplier = json.optDouble("multiplier", 1.0),
                    resetEpochSeconds = json.optLong("resetEpochSeconds"),
                    suspended = json.optBoolean("suspended"),
                    policyViolation = json.optBoolean("policyViolation"),
                ),
                checked,
            )
        }.getOrNull()
    }
}
