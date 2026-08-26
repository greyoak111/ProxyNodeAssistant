package com.proxynodeassistant.android.data

import com.proxynodeassistant.android.model.KiwiUsage
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

class ProviderTrafficClient {
    fun kiwiServiceInfo(veid: String, apiKey: String, useLocalProxy: Boolean): KiwiUsage {
        require(veid.matches(Regex("^[0-9]{3,12}$"))) { "VEID must contain 3-12 digits" }
        require(apiKey.length in 12..256 && apiKey.none(Char::isWhitespace)) { "Invalid KiwiVM API key" }
        val proxy = if (useLocalProxy) Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", 10808)) else Proxy.NO_PROXY
        val connection = URL("https://api.64clouds.com/v1/getServiceInfo").openConnection(proxy) as HttpURLConnection
        val body = "veid=${encode(veid)}&api_key=${encode(apiKey)}"
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 12_000
            connection.readTimeout = 18_000
            connection.useCaches = false
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", "TextNodeAssistant-Android/0.9.5")
            connection.outputStream.use { it.write(body.toByteArray(StandardCharsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val raw = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
            require(status in 200..299) { "KiwiVM returned HTTP $status" }
            require(raw.length in 2..1_000_000) { "KiwiVM returned an empty or oversized response" }
            val json = JSONObject(raw)
            val error = json.optInt("error", -1)
            require(error == 0) { json.optString("message", "KiwiVM API rejected the request").take(240) }
            val multiplier = json.optDouble("monthly_data_multiplier", 1.0).takeIf { it > 0.0 } ?: 1.0
            val used = json.optLong("data_counter", -1).toDouble() * multiplier
            val allowance = json.optLong("plan_monthly_data", -1).toDouble() * multiplier
            require(used >= 0.0 && allowance > 0.0) { "KiwiVM response is missing valid transfer counters" }
            return KiwiUsage(
                veid = veid,
                hostname = json.optString("hostname").take(128),
                location = json.optString("node_location").take(128),
                plan = json.optString("plan").take(128),
                usedBytes = used.toLong(),
                allowanceBytes = allowance.toLong(),
                multiplier = multiplier,
                resetEpochSeconds = json.optLong("data_next_reset", 0),
                suspended = json.optBoolean("suspended", false),
                policyViolation = json.optBoolean("policy_violation", false),
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun encode(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8.name())
}
