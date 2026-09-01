package com.proxynodeassistant.android.remote

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/** A public-address observation made before opening an SSH session. */
internal data class AndroidPublicIpObservation(
    val ip: String,
    val sources: List<String>,
    val successfulSources: Int,
) {
    val quorum: String get() = "${sources.size}/$successfulSources"
}

/** A deliberately layered probe; it is not a VLESS/SS throughput benchmark. */
internal data class AndroidRouteProbe(
    val name: String,
    val target: String,
    val layer: String,
    val ok: Boolean,
    val detail: String,
    val elapsedMs: Long,
)

internal object AndroidNetworkProbes {
    val publicIpv4Endpoints: List<String> = listOf(
        "https://api.ipify.org",
        "https://checkip.amazonaws.com",
        "https://ipv4.icanhazip.com",
        "https://ifconfig.me/ip",
    )

    /** Accept only one exact, globally routable IPv4 address; never accept CIDR. */
    fun normalizePublicIpv4(raw: String): String? {
        val value = raw.trim().lineSequence().flatMap { it.trim().split(Regex("\\s+")) }.firstOrNull().orEmpty()
        val parts = value.split('.')
        if (parts.size != 4 || parts.any { it.isEmpty() || (it.length > 1 && it.startsWith('0')) }) return null
        val octets = parts.map { it.toIntOrNull() ?: return null }
        if (octets.any { it !in 0..255 }) return null
        val first = octets[0]
        val isPrivate = first == 10 || first == 127 || (first == 172 && octets[1] in 16..31) || (first == 192 && octets[1] == 168)
        val isCarrierNat = first == 100 && octets[1] in 64..127
        val isDocumentation = (first == 192 && octets[1] == 0 && octets[2] == 2) ||
            (first == 198 && octets[1] == 51 && octets[2] == 100) ||
            (first == 203 && octets[1] == 0 && octets[2] == 113)
        val isBenchmark = first == 198 && octets[1] in 18..19
        val isSpecial = first == 0 || first >= 224 || (first == 169 && octets[1] == 254)
        if (isPrivate || isCarrierNat || isDocumentation || isBenchmark || isSpecial) return null
        return octets.joinToString(".")
    }

    suspend fun detectPublicIpv4(endpoints: List<String> = publicIpv4Endpoints): AndroidPublicIpObservation = withContext(Dispatchers.IO) {
        require(endpoints.isNotEmpty()) { "no public-IP endpoints configured" }
        val results = coroutineScope {
            endpoints.distinct().map { endpoint ->
                async(Dispatchers.IO) {
                    endpoint to runCatching {
                        val connection = URL(endpoint).openConnection(Proxy.NO_PROXY) as HttpURLConnection
                        connection.connectTimeout = 8_000
                        connection.readTimeout = 8_000
                        connection.instanceFollowRedirects = false
                        connection.requestMethod = "GET"
                        connection.setRequestProperty("Cache-Control", "no-cache")
                        try {
                            if (connection.responseCode !in 200..299) throw IOException("HTTP ${connection.responseCode}")
                            connection.inputStream.bufferedReader().use { reader ->
                                // Public-IP endpoints return one short line. Reading only the
                                // first 128 characters keeps a broken endpoint from allocating
                                // unbounded memory in the APK.
                                normalizePublicIpv4(reader.readLine()?.take(128).orEmpty()) ?: throw IOException("invalid IPv4 response")
                            }
                        } finally {
                            connection.disconnect()
                        }
                    }.getOrNull()
                }
            }.awaitAll()
        }
        val valid = results.mapNotNull { (endpoint, value) -> value?.let { endpoint to it } }
        if (valid.isEmpty()) throw IOException("all direct public-IP lookups failed")
        val grouped = valid.groupBy({ it.second }, { it.first })
        val selected = grouped.entries.sortedWith(compareByDescending<Map.Entry<String, List<String>>> { it.value.size }.thenBy { it.key }).first()
        AndroidPublicIpObservation(selected.key, selected.value.sorted(), valid.size)
    }

    fun tcpProbe(name: String, host: String, port: Int, timeoutMs: Int = 8_000): AndroidRouteProbe {
        val target = "$host:$port"
        val started = System.nanoTime()
        return try {
            Socket().use { socket -> socket.connect(InetSocketAddress(host, port), timeoutMs) }
            AndroidRouteProbe(name, target, "TCP_GATE", true, "TCP connected", elapsedMs(started))
        } catch (error: Throwable) {
            AndroidRouteProbe(name, target, "TCP_GATE", false, safeDetail(error), elapsedMs(started))
        }
    }

    /**
     * Attempts a TLS ClientHello after connecting. Reality uses a special authenticated
     * handshake, so a TCP success with a TLS failure is reported as reached-but-unverified,
     * never as a successful Reality/VLESS session.
     */
    fun realityProbe(host: String, port: Int, serverName: String?, timeoutMs: Int = 8_000): AndroidRouteProbe {
        val target = "$host:$port"
        val started = System.nanoTime()
        var connected = false
        return try {
            val context = permissiveTlsContext()
            val socket = context.socketFactory.createSocket() as SSLSocket
            socket.use { tls ->
                tls.connect(InetSocketAddress(host, port), timeoutMs)
                connected = true
                serverName?.takeIf { it.isNotBlank() }?.let { sni ->
                    runCatching { tls.sslParameters = tls.sslParameters.apply { serverNames = listOf(SNIHostName(sni)) } }
                }
                tls.soTimeout = timeoutMs
                runCatching { tls.startHandshake() }.fold(
                    onSuccess = {
                        val version = tls.session.protocol ?: "unknown"
                        AndroidRouteProbe("REALITY", target, "TCP_TLS_CLIENT_HELLO", true, "TLS $version; SNI=${serverName.orEmpty().ifBlank { "none" }} (layer probe only)", elapsedMs(started))
                    },
                    onFailure = { error ->
                        AndroidRouteProbe("REALITY", target, "TCP_TLS_CLIENT_HELLO", true, "TCP connected; TLS handshake not authenticated (${safeDetail(error)})", elapsedMs(started))
                    },
                )
            }
        } catch (error: Throwable) {
            val prefix = if (connected) "TCP connected; " else ""
            AndroidRouteProbe("REALITY", target, "TCP_TLS_CLIENT_HELLO", connected, prefix + safeDetail(error), elapsedMs(started))
        }
    }

    fun cdnHttpsProbe(domain: String, port: Int, timeoutMs: Int = 10_000): AndroidRouteProbe {
        val target = "https://$domain:$port/"
        val started = System.nanoTime()
        return try {
            val connection = URL(target).openConnection(Proxy.NO_PROXY) as HttpsURLConnection
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Cache-Control", "no-cache")
            try {
                val status = connection.responseCode
                runCatching { (connection.inputStream ?: connection.errorStream)?.close() }
                val ray = connection.getHeaderField("CF-Ray")?.trim().orEmpty()
                val suffix = if (ray.isBlank()) "" else "; Cloudflare edge reached (CF-Ray present)"
                AndroidRouteProbe("CDN_XHTTP", target, "HTTPS_EDGE_ORIGIN", status in 100..599, "HTTP $status$suffix", elapsedMs(started))
            } finally {
                connection.disconnect()
            }
        } catch (error: Throwable) {
            AndroidRouteProbe("CDN_XHTTP", target, "HTTPS_EDGE_ORIGIN", false, safeDetail(error), elapsedMs(started))
        }
    }

    private fun elapsedMs(started: Long): Long = ((System.nanoTime() - started) / 1_000_000L).coerceAtLeast(0)

    private fun safeDetail(error: Throwable): String = (error.message ?: error.javaClass.simpleName).replace(Regex("[\\r\\n]+"), " ").take(240)

    private fun permissiveTlsContext(): SSLContext = SSLContext.getInstance("TLS").apply {
        val trustAll = object : X509TrustManager {
            override fun getAcceptedIssuers() = emptyArray<java.security.cert.X509Certificate>()
            override fun checkClientTrusted(chain: Array<out java.security.cert.X509Certificate>, authType: String) = Unit
            override fun checkServerTrusted(chain: Array<out java.security.cert.X509Certificate>, authType: String) = Unit
        }
        init(null, arrayOf<TrustManager>(trustAll), java.security.SecureRandom())
    }
}
