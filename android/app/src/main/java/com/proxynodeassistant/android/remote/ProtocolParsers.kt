package com.proxynodeassistant.android.remote

import com.proxynodeassistant.android.model.PanelMetadata
import com.proxynodeassistant.android.model.ToolkitProbe
import java.net.URI

object ProtocolParsers {
    const val HANDOFF_BEGIN = "__PNA_HANDOFF_BEGIN__"
    const val HANDOFF_END = "__PNA_HANDOFF_END__"
    const val PANEL_BEGIN = "__PNA_PANEL_META_BEGIN__"
    const val PANEL_END = "__PNA_PANEL_META_END__"
    const val TOOLKIT_BEGIN = "__PNA_TOOLKIT_PROBE_BEGIN__"
    const val TOOLKIT_END = "__PNA_TOOLKIT_PROBE_END__"

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
        val useful = listOf("PANEL_PORT", "PANEL_USERNAME", "PANEL_PASSWORD", "PANEL_API_TOKEN", "VPS_LOGIN_PASSWORD", "UUID", "REALITY_PRIVATE_KEY", "REALITY_PUBLIC_KEY", "VLESS_LINK", "SS2022_LINK", "SS2022_PASSWORD", "SS2022_PORT", "COVER_DOMAIN", "PUBLIC_IP_AT_HANDOFF")
        require(useful.any { values[it].orEmpty().isNotBlank() }) { "handoff contains no verified credential or runtime field" }
        return payload
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
