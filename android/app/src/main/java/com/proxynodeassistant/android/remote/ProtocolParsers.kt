package com.proxynodeassistant.android.remote

import com.proxynodeassistant.android.model.PanelMetadata
import com.proxynodeassistant.android.model.StableNodeIdentity
import com.proxynodeassistant.android.model.ToolkitProbe
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

object ProtocolParsers {
    data class CdnXHttpLink(val uuid: String, val domain: String, val port: Int, val path: String, val label: String)

    const val HANDOFF_BEGIN = "__PNA_HANDOFF_BEGIN__"
    const val HANDOFF_END = "__PNA_HANDOFF_END__"
    const val PANEL_BEGIN = "__PNA_PANEL_META_BEGIN__"
    const val PANEL_END = "__PNA_PANEL_META_END__"
    const val TOOLKIT_BEGIN = "__PNA_TOOLKIT_PROBE_BEGIN__"
    const val TOOLKIT_END = "__PNA_TOOLKIT_PROBE_END__"
	const val NODE_IDENTITY_BEGIN = "__PNA_NODE_IDENTITY_V1_BEGIN__"
	const val NODE_IDENTITY_END = "__PNA_NODE_IDENTITY_V1_END__"

    fun markedBlock(value: String, begin: String, end: String): String {
        val lines = SshHandle.stripAnsi(value).replace("\r\n", "\n").lines()
        val start = lines.indexOfFirst { it.trim() == begin }
        require(start >= 0) { "required begin marker is missing" }
        val relativeFinish = lines.drop(start + 1).indexOfFirst { it.trim() == end }
        val finish = if (relativeFinish >= 0) start + 1 + relativeFinish else -1
        require(finish > start) { "required end marker is missing" }
        return lines.subList(start + 1, finish).joinToString("\n").trim().also { require(it.isNotEmpty()) { "marked output is empty" } }
    }

    fun kv(value: String): Map<String, String> = buildMap {
        value.replace("\r\n", "\n").lines().forEach { raw ->
            val line = raw.trim()
            val separator = line.indexOf('=')
            if (separator <= 0) return@forEach
            val key = line.substring(0, separator).trim()
            if (key.matches(Regex("^[A-Z][A-Z0-9_]*$"))) put(key, line.substring(separator + 1).trim())
        }
    }

    fun handoff(value: String): String {
        val payload = markedBlock(value, HANDOFF_BEGIN, HANDOFF_END)
        val values = kv(payload)
        require(values["HANDOFF_RUN_STARTED"].orEmpty().isNotBlank()) { "handoff run marker is missing" }
        val useful = listOf("PANEL_PORT", "PANEL_USERNAME", "PANEL_PASSWORD", "PANEL_API_TOKEN", "VPS_LOGIN_PASSWORD", "UUID", "REALITY_PRIVATE_KEY", "REALITY_PUBLIC_KEY", "VLESS_LINK", "COVER_DOMAIN", "PUBLIC_IP_AT_HANDOFF")
        require(useful.any { values[it].orEmpty().isNotBlank() }) { "handoff contains no verified credential or runtime field" }
        return payload
    }

    fun completeHandoff(legacy: String, fields: Map<String, String>): String {
        require(legacy.isNotEmpty() && '\u0000' !in legacy) { "legacy handoff is empty or contains NUL" }
        val lines = fields.toSortedMap().map { (key, value) ->
            require(key.matches(Regex("^[A-Z][A-Z0-9_]{0,63}$"))) { "invalid handoff appendix key" }
            require(value.none { it == '\r' || it == '\n' || it == '\u0000' }) { "invalid handoff appendix value" }
            "$key=$value"
        }
        return buildString {
            append(legacy)
            val formKeys = listOf("FORM_VPS_ACCOUNT", "FORM_VPS_PASSWORD", "FORM_PANEL_ACCOUNT", "FORM_PANEL_PASSWORD")
            if (formKeys.all { fields[it].orEmpty().isNotBlank() }) {
                append("\n\n===== 必须保存的登录凭据 / REQUIRED LOGIN CREDENTIALS =====\n")
                append("VPS_ACCOUNT=${fields.getValue("FORM_VPS_ACCOUNT")}\n")
                append("VPS_PASSWORD=${fields.getValue("FORM_VPS_PASSWORD")}\n")
                append("PANEL_ACCOUNT=${fields.getValue("FORM_PANEL_ACCOUNT")}\n")
                append("PANEL_PASSWORD=${fields.getValue("FORM_PANEL_PASSWORD")}\n")
                fields["FORM_PANEL_LOCAL_URL"]?.takeIf { it.isNotBlank() }?.let { append("PANEL_LOCAL_URL=$it\n") }
                append("===== END REQUIRED LOGIN CREDENTIALS =====")
            }
            append("\n\n===== PNA COMPLETE HANDOFF v0.9.5 =====\n")
            lines.filterNot { it.startsWith("FORM_") }.forEach { append(it).append('\n') }
            append("===== END PNA COMPLETE HANDOFF v0.9.5 =====")
        }
    }

    fun loginCredentialForm(legacy: String): Map<String, String> {
        val values = kv(legacy)
        val form = linkedMapOf(
            "FORM_VPS_ACCOUNT" to values["VPS_LOGIN_USER"].orEmpty(),
            "FORM_VPS_PASSWORD" to values["VPS_LOGIN_PASSWORD"].orEmpty(),
            "FORM_PANEL_ACCOUNT" to values["PANEL_USERNAME"].orEmpty(),
            "FORM_PANEL_PASSWORD" to values["PANEL_PASSWORD"].orEmpty(),
        )
        form.forEach { (key, raw) ->
            val value = raw.trim()
            val upper = value.uppercase()
            require(value.isNotEmpty() && !upper.startsWith("UNKNOWN") && !upper.startsWith("NOT_RETAINED") && upper != "SSH_KEY_ONLY") {
                "required login credential form is incomplete: ${key.removePrefix("FORM_")}"
            }
        }
        return form
    }

    fun cdnXHttpLink(value: String): CdnXHttpLink {
        val parsed = URI(value.trim())
        require(parsed.scheme == "vless" && !parsed.userInfo.isNullOrBlank() && ':' !in parsed.userInfo) { "invalid VLESS URL" }
        val uuid = parsed.userInfo
        val domain = parsed.host.orEmpty()
        val port = parsed.port
        require(uuid.matches(Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$"))) { "invalid UUID" }
        require(domain.matches(Regex("^([A-Za-z0-9][A-Za-z0-9-]*\\.)+[A-Za-z]{2,63}$"))) { "invalid hostname" }
        require(port == 443 || port == 8443) { "invalid CDN XHTTP port" }
        val query = linkedMapOf<String, MutableList<String>>()
        parsed.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.forEach { item ->
            val split = item.indexOf('=')
            require(split > 0) { "invalid query field" }
            val key = URLDecoder.decode(item.substring(0, split), StandardCharsets.UTF_8.name())
            val decoded = URLDecoder.decode(item.substring(split + 1), StandardCharsets.UTF_8.name())
            query.getOrPut(key) { mutableListOf() }.add(decoded)
        }
        fun exact(key: String, expected: String) {
            require(query[key] == listOf(expected)) { "missing, duplicated, or invalid $key" }
        }
        exact("encryption", "none")
        exact("security", "tls")
        exact("sni", domain)
        exact("fp", "chrome")
        exact("type", "xhttp")
        exact("host", domain)
        exact("mode", "packet-up")
        val path = query["path"]?.singleOrNull().orEmpty()
        require(path.matches(Regex("^/[0-9a-f]{32}/$"))) { "invalid XHTTP path" }
        val expectedLabel = if (port == 8443) "PNA-CDN-XHTTP-STAGE" else "PNA-CDN-XHTTP"
        require(parsed.fragment == expectedLabel) { "invalid profile label" }
        return CdnXHttpLink(uuid, domain, port, path, expectedLabel)
    }

    fun panel(value: String): PanelMetadata {
        val values = kv(markedBlock(value, PANEL_BEGIN, PANEL_END))
        val port = values["PANEL_PORT"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: error("invalid or empty panel port")
        var path = values["WEB_BASE_PATH"].orEmpty().trim()
        require(path.isNotBlank() && path.none { it in "\r\n\t ?#\\" }) { "unsafe or empty panel path" }
        if (!path.startsWith('/')) path = "/$path"
        if (!path.endsWith('/')) path += "/"
        val parsed = URI(path)
        require(!parsed.isAbsolute && parsed.query == null && parsed.fragment == null) { "invalid panel path" }
        return PanelMetadata(port, path, values["PANEL_METADATA_SOURCE"].orEmpty())
    }

    fun toolkit(value: String): ToolkitProbe {
        val values = kv(markedBlock(value, TOOLKIT_BEGIN, TOOLKIT_END))
        when (values["TOOLKIT_PRESENT"]) {
            "0" -> return ToolkitProbe(false, false)
            "1" -> Unit
            else -> error("invalid toolkit presence flag")
        }
        val version = values["TOOLKIT_VERSION"].orEmpty().removePrefix("v")
        require(version.matches(Regex("^[0-9]+(?:\\.[0-9]+){1,3}$"))) { "invalid toolkit version" }
        val revision = values["TOOLKIT_BUILD_REVISION"].orEmpty().toIntOrNull() ?: 0
        require(revision in 0..1_000_000_000) { "invalid build revision" }
        val complete = when (values["TOOLKIT_COMPLETE"]) {
            "0" -> false
            "1" -> true
            else -> error("invalid toolkit completeness flag")
        }
        return ToolkitProbe(true, complete, version, values["TOOLKIT_BUILD_ID"].orEmpty(), revision)
    }

	fun stableNodeIdentity(value: String, targetId: String): StableNodeIdentity {
		val values = kv(markedBlock(value, NODE_IDENTITY_BEGIN, NODE_IDENTITY_END))
		val serverId = values["SERVER_ID"].orEmpty()
		val nodeId = values["NODE_ID"].orEmpty()
		val machine = values["MACHINE_ID_SHA256"].orEmpty()
		val hostKey = values["SSH_HOST_KEY_SHA256"].orEmpty()
		val firstIp = values["FIRST_KNOWN_PUBLIC_IP"].orEmpty()
		val currentIp = values["CURRENT_PUBLIC_IP"].orEmpty()
		require(serverId.matches(Regex("^pna-srv-[0-9a-f]{32}$"))) { "invalid SERVER_ID" }
		require(nodeId.matches(Regex("^pna-node-[0-9a-f]{32}$"))) { "invalid NODE_ID" }
		require(machine.matches(Regex("^[0-9a-f]{64}$"))) { "invalid machine-id hash" }
		require(hostKey.matches(Regex("^SHA256:[A-Za-z0-9+/]+$"))) { "invalid host-key fingerprint" }
		require(values["MACHINE_ID_MATCH"] == "1" && values["SSH_HOST_KEY_MATCH"] == "1") { "stable node identity mismatch" }
		require(validCanonicalPublicIpv4(firstIp) && validCanonicalPublicIpv4(currentIp)) { "invalid stable public IPv4" }
		return StableNodeIdentity(targetId, serverId, nodeId, machine, hostKey, firstIp, currentIp)
	}

	fun validCanonicalPublicIpv4(value: String): Boolean {
		val parts = value.split('.')
		if (parts.size != 4 || parts.any { it.isEmpty() || (it.length > 1 && it.startsWith('0')) || it.toIntOrNull() !in 0..255 }) return false
		val a = parts[0].toInt(); val b = parts[1].toInt(); val c = parts[2].toInt()
		return when {
			a == 0 || a == 10 || a == 127 || a >= 224 -> false
			a == 100 && b in 64..127 -> false
			a == 169 && b == 254 -> false
			a == 172 && b in 16..31 -> false
			a == 192 && b == 168 -> false
			a == 192 && b == 0 && (c == 0 || c == 2) -> false
			a == 198 && b in 18..19 -> false
			a == 198 && b == 51 && c == 100 -> false
			a == 203 && b == 0 && c == 113 -> false
			else -> true
		}
	}

    fun compareVersions(left: String, right: String): Int {
        fun parts(value: String) = value.removePrefix("v").split('.').map { it.toInt() }
        val a = parts(left)
        val b = parts(right)
        for (index in 0 until maxOf(a.size, b.size)) {
            val result = (a.getOrElse(index) { 0 }).compareTo(b.getOrElse(index) { 0 })
            if (result != 0) return result
        }
        return 0
    }
}
