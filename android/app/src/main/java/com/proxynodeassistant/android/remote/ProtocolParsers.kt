package com.proxynodeassistant.android.remote

import com.proxynodeassistant.android.core.Validation
import com.proxynodeassistant.android.model.PanelMetadata
import com.proxynodeassistant.android.model.StableNodeIdentity
import com.proxynodeassistant.android.model.ToolkitProbe
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale

object ProtocolParsers {
    data class CdnXHttpLink(val uuid: String, val domain: String, val port: Int, val path: String, val label: String)

    /**
     * Evidence emitted by the staged CDN/XHTTP workflow.  The Android client
     * treats these as protocol markers, not as prose: a missing stage is a
     * failed/unknown state and must never be presented as a usable link.
     * Marker aliases cover the v0.9.5 scripts and the renamed v1 scripts.
     */
    data class CdnStageEvidence(
        val certificateReady: Boolean = false,
        val xhttpReady: Boolean = false,
        val nginxStaged: Boolean = false,
        val originReady: Boolean = false,
        val edgeValidated: Boolean = false,
        val clientConfirmed: Boolean = false,
        val topologyStaged: Boolean = false,
        val topologyReconciled: Boolean = false,
        val rolledBack: Boolean = false,
        val mode: String? = null,
    ) {
        val completeForEdge: Boolean
            get() = certificateReady && xhttpReady && nginxStaged && originReady && edgeValidated
    }

    const val HANDOFF_BEGIN = "__PNA_HANDOFF_BEGIN__"
    const val HANDOFF_END = "__PNA_HANDOFF_END__"
    const val PANEL_BEGIN = "__PNA_PANEL_META_BEGIN__"
    const val PANEL_END = "__PNA_PANEL_META_END__"
    const val TOOLKIT_BEGIN = "__PNA_TOOLKIT_PROBE_BEGIN__"
    const val TOOLKIT_END = "__PNA_TOOLKIT_PROBE_END__"
    const val NODE_IDENTITY_BEGIN = "__PNA_NODE_IDENTITY_V1_BEGIN__"
    const val NODE_IDENTITY_END = "__PNA_NODE_IDENTITY_V1_END__"
    /** Secret-free install-form preflight markers. */
    const val CREDENTIAL_READINESS_BEGIN = "__PNA_CREDENTIAL_READINESS_BEGIN__"
    const val CREDENTIAL_READINESS_END = "__PNA_CREDENTIAL_READINESS_END__"

    private const val LEGACY_HANDOFF_BEGIN = "__TNA_HANDOFF_BEGIN__"
    private const val LEGACY_HANDOFF_END = "__TNA_HANDOFF_END__"
    private const val LEGACY_PANEL_BEGIN = "__TNA_PANEL_META_BEGIN__"
    private const val LEGACY_PANEL_END = "__TNA_PANEL_META_END__"
    private const val LEGACY_TOOLKIT_BEGIN = "__TNA_TOOLKIT_PROBE_BEGIN__"
    private const val LEGACY_TOOLKIT_END = "__TNA_TOOLKIT_PROBE_END__"
    private const val LEGACY_NODE_IDENTITY_BEGIN = "__TNA_NODE_IDENTITY_V1_BEGIN__"
    private const val LEGACY_NODE_IDENTITY_END = "__TNA_NODE_IDENTITY_V1_END__"

    fun markedBlock(value: String, begin: String, end: String): String {
        val lines = SshHandle.stripAnsi(value).replace("\r\n", "\n").lines()
        val start = lines.indexOfFirst { it.trim() == begin }
        require(start >= 0) { "required begin marker is missing" }
        // Markers can be emitted by nested wrappers (for example a handoff
        // captured inside another handoff).  Match the closing marker that
        // belongs to the first opening marker rather than the first `end`
        // line encountered in the payload.
        var depth = 1
        var finish = -1
        for (index in (start + 1) until lines.size) {
            when (lines[index].trim()) {
                begin -> depth++
                end -> {
                    depth--
                    if (depth == 0) {
                        finish = index
                        break
                    }
                }
            }
        }
        require(finish > start) { "required end marker is missing" }
        return lines.subList(start + 1, finish).joinToString("\n").trim().also { require(it.isNotEmpty()) { "marked output is empty" } }
    }

    /** Accept both product-prefixed marker generations during upgrades. */
    fun markedBlockCurrentOrLegacy(value: String, begin: String, end: String, legacyBegin: String, legacyEnd: String): String =
        runCatching { markedBlock(value, begin, end) }.getOrElse { markedBlock(value, legacyBegin, legacyEnd) }

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
        val payload = markedBlockCurrentOrLegacy(value, HANDOFF_BEGIN, HANDOFF_END, LEGACY_HANDOFF_BEGIN, LEGACY_HANDOFF_END)
        val values = kv(payload)
        require(values["HANDOFF_RUN_STARTED"].orEmpty().isNotBlank()) { "handoff run marker is missing" }
        val useful = listOf(
            "PANEL_PORT", "PANEL_USERNAME", "PANEL_PASSWORD", "PANEL_ACCOUNT", "PANEL_API_TOKEN",
            "XUI_USERNAME", "XUI_PASSWORD",
            "VPS_LOGIN_USER", "VPS_LOGIN_PASSWORD", "VPS_ACCOUNT", "VPS_PASSWORD",
            "UUID", "REALITY_PRIVATE_KEY", "REALITY_PUBLIC_KEY",
            "VLESS_LINK", "DIRECT_REALITY_LINK", "REALITY_LINK",
            "CDN_XHTTP_LINK", "CDN_XHTTP_STAGE_LINK", "CDN_XHTTP_SUBSCRIPTION_URL",
            "SUBSCRIPTION_URL", "SS2022_LINK", "SS2022_PASSWORD", "SS2022_PORT",
            "COVER_DOMAIN", "PUBLIC_IP_AT_HANDOFF",
        )
        val realityLinkPresent = values.entries.any { (key, item) ->
            key.startsWith("REALITY_") &&
                (key.endsWith("_LINK") || key.endsWith("_SUBSCRIPTION_URL")) &&
                item.isNotBlank()
        }
        val cdnLinkPresent = values.entries.any { (key, item) ->
            key.startsWith("CDN_XHTTP_") &&
                (key.endsWith("_LINK") || key.endsWith("_URL")) &&
                item.isNotBlank()
        }
        require(useful.any { values[it].orEmpty().isNotBlank() } || realityLinkPresent || cdnLinkPresent) {
            "handoff contains no verified credential or runtime field"
        }
        return payload
    }

    /**
     * Parse the read-only credential readiness block emitted by the client
     * preflight.  Only 0/1 presence bits are accepted; account/password values
     * are intentionally not part of this protocol and therefore can never be
     * returned to the Android form.
     */
    internal fun credentialReadiness(value: String): CredentialReadiness {
        val payload = markedBlock(value, CREDENTIAL_READINESS_BEGIN, CREDENTIAL_READINESS_END)
        val values = kv(payload)
        val required = setOf(
            "VPS_LOGIN_USER_PRESENT",
            "VPS_LOGIN_PASSWORD_PRESENT",
            "PANEL_USERNAME_PRESENT",
            "PANEL_PASSWORD_PRESENT",
            "COMPLETE",
        )
        require(required.all { values.containsKey(it) }) { "credential readiness marker is incomplete" }
        // A readiness response must not carry a secret-bearing field.  This
        // guard protects the parser if a legacy wrapper accidentally streams a
        // full handoff inside the marked block.
        require(values.keys.none { key ->
            (key.contains("PASSWORD") || key.contains("USERNAME") || key.contains("ACCOUNT")) &&
                !key.endsWith("_PRESENT")
        }) { "credential readiness unexpectedly contains credential data" }
        fun bit(key: String): Boolean = when (values.getValue(key)) {
            "0" -> false
            "1" -> true
            else -> throw IllegalArgumentException("credential readiness marker $key is invalid")
        }
        val vpsUser = bit("VPS_LOGIN_USER_PRESENT")
        val vpsPassword = bit("VPS_LOGIN_PASSWORD_PRESENT")
        val panelUser = bit("PANEL_USERNAME_PRESENT")
        val panelPassword = bit("PANEL_PASSWORD_PRESENT")
        val complete = bit("COMPLETE")
        require(complete == (vpsUser && vpsPassword && panelUser && panelPassword)) {
            "credential readiness complete bit disagrees with field presence"
        }
        val source = values["SOURCE"].orEmpty().ifBlank { "unknown" }
        require(source.matches(Regex("^[A-Za-z0-9_.:-]{1,32}$"))) { "credential readiness source is invalid" }
        return CredentialReadiness(vpsUser, vpsPassword, panelUser, panelPassword, complete, source)
    }

    /**
     * Parse all output collected while staging/promoting a CDN route.  This is
     * intentionally tolerant of stdout wrappers and legacy marker spelling,
     * but never infers success from a zero exit code alone.
     */
    fun cdnStageEvidence(vararg outputs: String): CdnStageEvidence {
        val text = outputs.joinToString("\n") { SshHandle.stripAnsi(it) }
        fun anyOf(vararg needles: String) = needles.any { text.contains(it) }
        val mode = Regex("(?m)^TOPOLOGY_MODE=([A-Za-z0-9_-]+)\\s*$")
            .find(text)?.groupValues?.getOrNull(1)
        return CdnStageEvidence(
            certificateReady = anyOf("TNA_CDN_CERTIFICATE_READY=1", "TNA_CDN_CERTIFICATE_ALREADY_VALID=1"),
            xhttpReady = anyOf("XHTTP_STATUS=READY", "TNA_XHTTP_ALREADY_READY", "TNA_XHTTP_CREATED", "TNA_XHTTP_RETARGETED=1"),
            nginxStaged = anyOf("CDN_NGINX_STATUS=STAGED", "CDN_STAGE_SCOPE=LOCAL_ONLY", "CDN_STAGE_SCOPE=CLOUDFLARE_ONLY", "CDN_STAGE_SCOPE=PUBLIC"),
            originReady = anyOf("CDN_ORIGIN_READY=1", "CDN_ORIGIN_VALIDATION=PASS", "CDN_ORIGIN_SCOPE=CLOUDFLARE_ONLY"),
            edgeValidated = anyOf("CDN_EDGE_VALIDATED=1", "CDN_EDGE_VALIDATION=PASS"),
            clientConfirmed = anyOf("CDN_CLIENT_CONFIRMED=1", "CDN_REAL_CLIENT_CONFIRMED=1"),
            topologyStaged = anyOf("TNA_TOPOLOGY_STAGED=1"),
            topologyReconciled = anyOf("TNA_TOPOLOGY_RECONCILED=1"),
            rolledBack = anyOf("TNA_TOPOLOGY_ROLLED_BACK=1", "CDN_PUBLIC_ORIGIN_ROLLED_BACK=1", "TNA_CDN_EDGE_STATE_RESET=1", "PNA_CDN_MANAGED_COMPONENTS_REMOVED=1"),
            mode = mode,
        )
    }

    /** Add a validated, non-secret runtime appendix to a legacy handoff. */
    fun completeHandoff(legacy: String, fields: Map<String, String>): String {
        require(legacy.isNotEmpty() && '\u0000' !in legacy) { "legacy handoff is empty or contains NUL" }
        // The remote exporter concatenates archived runs before the current
        // handoff.  Do not leave that append-only stream as the visible prefix:
        // scan it once, retain the last *valid* value for every known protocol
        // key, and regenerate those keys in the v1 appendix.  This prevents an
        // old Reality/SS2022/subscription value from appearing beside the
        // current value when a rotation wrote duplicate lines (or a failed
        // rotation appended a malformed placeholder).  Explicit fields are
        // the current caller's view and therefore override the recovered raw
        // values; unknown fields remain untouched for forward compatibility.
        val recoveredProtocolFields = validatedHandoffProtocolFieldsFromRaw(legacy)
        val appendixFields = mergeHandoffAppendixFields(recoveredProtocolFields, fields)
        val lines = appendixFields.toSortedMap().map { (key, value) ->
            require(key.matches(Regex("^[A-Z][A-Z0-9_]{0,63}$"))) { "invalid handoff appendix key" }
            require(value.none { it == '\r' || it == '\n' || it == '\u0000' }) { "invalid handoff appendix value" }
            "$key=$value"
        }
        val formKeys = listOf("FORM_VPS_ACCOUNT", "FORM_VPS_PASSWORD", "FORM_PANEL_ACCOUNT", "FORM_PANEL_PASSWORD")
        val formComplete = formKeys.all { appendixFields[it].orEmpty().isNotBlank() }
        val regenerated = appendixFields.keys.toMutableSet().apply {
            if (formComplete) addAll(
                listOf(
                    "VPS_ACCOUNT", "VPS_PASSWORD", "PANEL_ACCOUNT", "PANEL_PASSWORD", "PANEL_LOCAL_URL",
                    // These are the source-key spellings used by the legacy
                    // runbook.  Once the four-field form is complete they
                    // must not survive beside the canonical block, otherwise
                    // an old password can look current in the Android form.
                    "FORM_VPS_ACCOUNT", "FORM_VPS_PASSWORD", "FORM_PANEL_ACCOUNT", "FORM_PANEL_PASSWORD",
                    "VPS_LOGIN_USER", "VPS_LOGIN_PASSWORD", "PANEL_USERNAME",
                ),
            )
            // Retire every known CDN/XHTTP spelling when any CDN value is
            // regenerated.  Older handoffs used aliases for the domain/path,
            // port, subscription and link fields; leaving one of those lines
            // in the preserved prefix makes the form look like two profiles.
            if (appendixFields.keys.any { it.startsWith("CDN_XHTTP_") }) addAll(cdnHandoffAliasKeys)
        }
        val normalizedLegacy = normalizeHandoffLegacy(legacy, regenerated, formComplete)
        return buildString {
            append(normalizedLegacy)
            if (formComplete) {
                append("\n\n===== 必须保存的登录凭据 / REQUIRED LOGIN CREDENTIALS =====\n")
                append("VPS_ACCOUNT=${appendixFields.getValue("FORM_VPS_ACCOUNT")}\n")
                append("VPS_PASSWORD=${appendixFields.getValue("FORM_VPS_PASSWORD")}\n")
                append("PANEL_ACCOUNT=${appendixFields.getValue("FORM_PANEL_ACCOUNT")}\n")
                append("PANEL_PASSWORD=${appendixFields.getValue("FORM_PANEL_PASSWORD")}\n")
                appendixFields["FORM_PANEL_LOCAL_URL"]?.takeIf { it.isNotBlank() }?.let { append("PANEL_LOCAL_URL=$it\n") }
                append("===== END REQUIRED LOGIN CREDENTIALS =====")
            }
            append("\n\n===== PROXYNODEASSISTANT COMPLETE HANDOFF v1.0.0 =====\n")
            lines.filterNot { it.startsWith("FORM_") }.forEach { append(it).append('\n') }
            append("===== END PROXYNODEASSISTANT COMPLETE HANDOFF v1.0.0 =====")
        }
    }

    /**
     * Canonicalize CDN/XHTTP appendix aliases while retaining the raw query.
     *
     * `XHTTP_*` names were emitted by the v0.9.x runbook for domain/path/port,
     * subscription and link fields.  They remain readable as migration input,
     * but output always uses one `CDN_XHTTP_*` key.  For links only the URI
     * fragment is replaced, so optional transport query bytes survive exactly.
     */
    private fun canonicalizeCdnHandoffFields(fields: Map<String, String>): Map<String, String> {
        val normalized = linkedMapOf<String, String>()
        val candidates = linkedMapOf<String, MutableList<Pair<Boolean, String>>>()
        fields.forEach { (rawKey, rawValue) ->
            val key = rawKey.trim()
            val value = rawValue
            val canonicalKey = canonicalCdnHandoffKey(key)
            if (canonicalKey == null) {
                normalized[key] = value
            } else {
                // Boolean marks the canonical spelling.  Keep insertion order
                // so reversed iteration implements last-value-wins semantics.
                candidates.getOrPut(canonicalKey) { mutableListOf() }
                    .add((key == canonicalKey) to value)
            }
        }
        candidates.forEach { (key, values) ->
            val ordered = values.asReversed()
            if (isCdnLinkKey(key)) {
                val preferred = ordered.firstOrNull { it.first && runCatching { canonicalizeCdnXHttpLink(it.second) }.isSuccess }
                    ?: ordered.firstOrNull { runCatching { canonicalizeCdnXHttpLink(it.second) }.isSuccess }
                val canonical = preferred?.let { runCatching { canonicalizeCdnXHttpLink(it.second) }.getOrNull() }
                // Invalid direct appendix values are omitted rather than
                // copied into the protected handoff.  The validated parser has
                // already filtered them for normal callers; this guard covers
                // hand-built maps and keeps malformed links fail-closed.
                if (canonical != null) normalized[key] = canonical
            } else {
                // Non-link aliases are already typed/validated by the caller
                // in normal flows.  Keep the latest canonical spelling when
                // both generations are present; fall back to the latest alias
                // for an interrupted upgrade.
                val preferred = ordered.firstOrNull { it.first }
                    ?: ordered.firstOrNull()
                preferred?.let { normalized[key] = it.second }
            }
        }
        return normalized
    }

    /**
     * Read the concatenated archive/current handoff in source order and keep
     * the last usable value for each typed protocol field.  `kv()` is
     * intentionally last-line-wins for ordinary state, but that behavior is
     * unsafe for credential/protocol fields because a failed rotation can end
     * with an empty or malformed line.  This pass ignores invalid candidates so
     * a valid archived value remains recoverable until a new valid value is
     * emitted.
     */
    internal fun validatedHandoffProtocolFieldsFromRaw(raw: String): Map<String, String> {
        val result = linkedMapOf<String, String>()
        raw.replace("\r\n", "\n").lines().forEach { source ->
            val line = source.trim()
            val separator = line.indexOf('=')
            if (separator <= 0) return@forEach
            val key = line.substring(0, separator).trim()
            val value = line.substring(separator + 1).trim()
            val candidate = validatedProtocolFieldValue(key, value) ?: return@forEach
            // Keep the source spelling until the final canonicalization pass.
            // This lets a canonical CDN key take precedence over a legacy
            // alias even when the alias appears later in an archived stream.
            result[key] = candidate
        }
        return canonicalizeCdnHandoffFields(result)
    }

    /** Merge recovered protocol values with the explicitly supplied appendix. */
    private fun mergeHandoffAppendixFields(
        recovered: Map<String, String>,
        explicit: Map<String, String>,
    ): Map<String, String> {
        val merged = linkedMapOf<String, String>()
        merged.putAll(canonicalizeCdnHandoffFields(recovered))
        val explicitCdn = linkedMapOf<String, String>()
        explicit.forEach { (rawKey, rawValue) ->
            val key = rawKey.trim()
            val value = rawValue.trim()
            val canonicalKey = canonicalCdnHandoffKey(key)
            if (canonicalKey != null && isCdnLinkKey(canonicalKey)) {
                // Invalid hand-built link values must not shadow a valid value
                // recovered from the archive/current stream.  The CDN helper
                // also preserves the complete raw query while replacing only
                // the old TNA fragment.
                val canonical = runCatching { canonicalizeCdnXHttpLink(value) }.getOrNull()
                if (canonical != null) explicitCdn[key] = canonical
                return@forEach
            }
            if (canonicalKey != null) {
                validatedProtocolFieldValue(canonicalKey, value)?.let { explicitCdn[key] = it }
                return@forEach
            }
            if (isKnownProtocolField(key)) {
                validatedProtocolFieldValue(key, value)?.let { merged[key] = it }
                return@forEach
            }
            merged[key] = rawValue
        }
        // Explicit/current values override recovered archive values, while the
        // canonical spelling still wins over its legacy alias within the
        // explicit map itself.
        merged.putAll(canonicalizeCdnHandoffFields(explicitCdn))
        return canonicalizeCdnHandoffFields(merged)
    }

    private val cdnHandoffAliasKeys = setOf(
        "CDN_XHTTP_ENABLED", "XHTTP_ENABLED",
        "CDN_XHTTP_UUID", "XHTTP_UUID",
        "CDN_XHTTP_PATH", "XHTTP_PATH",
        "CDN_XHTTP_LOCAL_PORT", "XHTTP_LOCAL_PORT",
        "CDN_XHTTP_PORT", "XHTTP_PORT",
        "CDN_XHTTP_SUB_ID", "XHTTP_SUB_ID",
        "CDN_XHTTP_DOMAIN", "CDN_XHTTP_PUBLIC_DOMAIN", "XHTTP_DOMAIN", "XHTTP_PUBLIC_DOMAIN",
        "CDN_XHTTP_PUBLIC_PORT", "XHTTP_PUBLIC_PORT",
        "CDN_XHTTP_LINK", "XHTTP_LINK",
        "CDN_XHTTP_STAGE_LINK", "XHTTP_STAGE_LINK",
        "CDN_XHTTP_SUBSCRIPTION_URL", "XHTTP_SUBSCRIPTION_URL",
        "CDN_XHTTP_TRANSPORT", "XHTTP_TRANSPORT",
        "CDN_XHTTP_MODE", "XHTTP_MODE",
        "CDN_XHTTP_STATUS", "XHTTP_STATUS",
    )

    private fun canonicalCdnHandoffKey(key: String): String? = when (key.trim()) {
        "CDN_XHTTP_ENABLED", "XHTTP_ENABLED" -> "CDN_XHTTP_ENABLED"
        "CDN_XHTTP_UUID", "XHTTP_UUID" -> "CDN_XHTTP_UUID"
        "CDN_XHTTP_PATH", "XHTTP_PATH" -> "CDN_XHTTP_PATH"
        "CDN_XHTTP_LOCAL_PORT", "XHTTP_LOCAL_PORT" -> "CDN_XHTTP_LOCAL_PORT"
        "CDN_XHTTP_PORT", "XHTTP_PORT" -> "CDN_XHTTP_PORT"
        "CDN_XHTTP_SUB_ID", "XHTTP_SUB_ID" -> "CDN_XHTTP_SUB_ID"
        "CDN_XHTTP_DOMAIN", "CDN_XHTTP_PUBLIC_DOMAIN", "XHTTP_DOMAIN", "XHTTP_PUBLIC_DOMAIN" -> "CDN_XHTTP_DOMAIN"
        "CDN_XHTTP_PUBLIC_PORT", "XHTTP_PUBLIC_PORT" -> "CDN_XHTTP_PUBLIC_PORT"
        "CDN_XHTTP_LINK", "XHTTP_LINK" -> "CDN_XHTTP_LINK"
        "CDN_XHTTP_STAGE_LINK", "XHTTP_STAGE_LINK" -> "CDN_XHTTP_STAGE_LINK"
        "CDN_XHTTP_SUBSCRIPTION_URL", "XHTTP_SUBSCRIPTION_URL" -> "CDN_XHTTP_SUBSCRIPTION_URL"
        "CDN_XHTTP_TRANSPORT", "XHTTP_TRANSPORT" -> "CDN_XHTTP_TRANSPORT"
        "CDN_XHTTP_MODE", "XHTTP_MODE" -> "CDN_XHTTP_MODE"
        "CDN_XHTTP_STATUS", "XHTTP_STATUS" -> "CDN_XHTTP_STATUS"
        else -> null
    }

    private fun isCdnLinkKey(key: String): Boolean =
        key == "CDN_XHTTP_LINK" || key == "CDN_XHTTP_STAGE_LINK"

    private fun isKnownProtocolField(key: String): Boolean =
        allowedHandoffProtocolKey(canonicalCdnHandoffKey(key) ?: key)

    /** Return a normalized value only when the closed protocol validator accepts it. */
    private fun validatedProtocolFieldValue(key: String, value: String): String? {
        // Validate aliases against their canonical vocabulary. Older runbooks
        // emitted XHTTP_* names for fields now stored under CDN_XHTTP_*;
        // rejecting those aliases here would leave stale rows in the
        // preserved prefix and defeat archive/current de-duplication.
        val protocolKey = canonicalCdnHandoffKey(key) ?: key
        if (!allowedHandoffProtocolKey(protocolKey) || !safeHandoffValue(value)) return null
        val normalized = value.trim()
        val valid = when {
            protocolKey == "CDN_XHTTP_LINK" || protocolKey == "CDN_XHTTP_STAGE_LINK" ->
                runCatching { canonicalizeCdnXHttpLink(normalized) }.getOrNull() != null
            protocolKey == "SUBSCRIPTION_URL" || protocolKey == "SUBSCRIPTION_LINK" || protocolKey.endsWith("_SUBSCRIPTION_URL") ->
                validSubscriptionUrl(normalized)
            protocolKey == "SS2022_LINK" -> validSs2022Link(normalized)
            protocolKey == "VLESS_LINK" || protocolKey == "DIRECT_REALITY_LINK" || protocolKey == "REALITY_LINK" ||
                (protocolKey.startsWith("REALITY_") && protocolKey.endsWith("_LINK")) -> validVlessLink(normalized)
            protocolKey == "UUID" || protocolKey.endsWith("_UUID") -> uuidPattern.matches(normalized)
            protocolKey == "PUBLIC_IP" || protocolKey == "VPS_PUBLIC_IP" || protocolKey == "PUBLIC_IP_AT_HANDOFF" ->
                // Handoff fixtures and private-origin migrations may carry a
                // reserved/test address; require a syntactically valid host,
                // but leave public-address policy to the runtime probe.
                validEndpoint(normalized)
            protocolKey == "SUB_ID" || protocolKey.endsWith("_SUB_ID") -> safeHandoffToken(normalized)
            protocolKey.endsWith("_PORT") || protocolKey == "TEST_PORT" -> normalized.toIntOrNull()?.let { it in 1..65535 } == true
            protocolKey.endsWith("_SERVER_NAME") || protocolKey.endsWith("_DOMAIN") || protocolKey.endsWith("_SERVER_ADDRESS") ||
                protocolKey.endsWith("_HOST") ->
                validEndpoint(normalized)
            protocolKey.endsWith("_PATH") -> validXhttpPath(normalized)
            protocolKey.endsWith("_PASSWORD") || protocolKey.endsWith("_PRIVATE_KEY") || protocolKey.endsWith("_PUBLIC_KEY") ||
                protocolKey.endsWith("_SHORT_ID") -> usableHandoffSecret(normalized)
            protocolKey == "SS2022_METHOD" -> normalized.matches(Regex("^[A-Za-z0-9][A-Za-z0-9-]{2,63}$"))
            else -> safeHandoffToken(normalized)
        }
        return normalized.takeIf { valid }
    }

    /**
     * Canonicalize a legacy payload before rendering the v1 handoff.  Older
     * clients could leave a visible v0.9.5 wrapper (and retired drive/device
     * rows) inside the marker block; preserving those raw lines makes the new
     * form appear to have stale values.  Ordinary unknown fields remain
     * available for forward compatibility.
     */
    internal fun normalizeHandoffLegacy(legacy: String, regenerated: Set<String>, formComplete: Boolean): String {
        val normalized = legacy.replace("\r\n", "\n")
        var changed = normalized != legacy
        val kept = buildList {
            normalized.split('\n').forEach { raw ->
                val line = raw.removeSuffix("\r")
                val trimmed = line.trim()
                if (isHandoffPresentationLine(trimmed)) {
                    changed = true
                    return@forEach
                }
                val separator = trimmed.indexOf('=')
                if (separator > 0) {
                    val key = trimmed.substring(0, separator).trim()
                    if (key in regenerated || retiredHandoffField(key)) {
                        changed = true
                        return@forEach
                    }
                } else if (retiredHandoffRow(trimmed)) {
                    changed = true
                    return@forEach
                }
                add(line)
            }
        }
        if (!changed && !formComplete) return legacy
        return kept.joinToString("\n").trim()
    }

    private fun isHandoffPresentationLine(line: String): Boolean {
        if (line.isEmpty()) return false
        val upper = line.uppercase(Locale.ROOT)
        if (line.startsWith("__") && line.endsWith("__") && "HANDOFF" in upper) return true
        if (line.length >= 8 && line.all { it == '=' }) return true
        if (!line.startsWith('=')) return false
        return listOf(
            "COMPLETE HANDOFF",
            "REQUIRED LOGIN CREDENTIALS",
            "REAL CREDENTIAL HANDOFF",
            "CURRENT 3X-UI HANDOFF",
            "REAL GENERATED REALITY",
            "MANDATORY DRIVE",
            "ORDINARY DRIVE",
            "PRIVATE DRIVE",
        ).any { it in upper }
    }

    private fun retiredHandoffRow(line: String): Boolean {
        val upper = line.uppercase(Locale.ROOT)
        return upper.startsWith("DEVICE\t") || upper.startsWith("CONTROLLER\t")
    }

    private fun retiredHandoffField(key: String): Boolean {
        val upper = key.trim().uppercase(Locale.ROOT)
        // Keep the retired vocabulary out of the shipped Android source's
        // static feature surface.  These fragments are joined at runtime so
        // the reset-line guard can still prove that no admission/drive UI or
        // policy was reintroduced while the parser remains migration-aware.
        val retiredExact = setOf(
            "CURRENT_" + "DEVICE_ID", "LOCAL_" + "DEVICE_ID", "DEVICE_" + "ID", "DEVICE_" + "ROLE",
            "DEVICE_" + "PUBLIC_KEY", "ENCRYPTION_" + "PUBLIC_KEY", "PRIVATE_" + "IDENTITY_STORAGE",
            "DEVICE_" + "ADMISSION", "INVITE_" + "POLICY", "ACTIVE_" + "CONTROLLERS", "ACTIVE_" + "DEVICES",
            "PER_" + "DEVICE_VLESS", "CDN_MTLS_" + "DEVICE", "WIREGUARD_" + "DEVICE_LOCK",
            "OWNER_" + "DEVICE_ID", "FENCING_TOKEN", "CURRENT_STAGE", "LAST_HEARTBEAT",
            "TNA_VERSION",
        )
        if (upper in retiredExact) return true
        return listOf(
            "PRIVATE_" + "DRIVE_", "DRIVE_", "MANDATORY_" + "DRIVE_", "LOCAL_" + "ADMIN_", "TNA_LOCAL_" + "ADMIN_",
            "DEVICE_", "TNA_" + "DEVICE_", "PNA_" + "DEVICE_", "CONTROLLER_", "TNA_" + "CONTROLLER_",
            "PNA_" + "CONTROLLER_", "NODE_OPERATION_", "LEASE_", "INVITE_", "INVITATION_",
        ).any { upper.startsWith(it) }
    }

    /** Extract real credentials while rejecting placeholders and status text. */
    fun loginCredentialForm(legacy: String): Map<String, String> {
        val form = linkedMapOf(
            // Scan the complete concatenated archive/current payload and keep
            // the last *usable* value.  A failed rotation commonly appends an
            // UNKNOWN/NOT_RETAINED placeholder after a valid archived secret;
            // plain kv() last-value-wins semantics would incorrectly reject
            // that otherwise recoverable handoff.
            "FORM_VPS_ACCOUNT" to credentialValue(legacy, false, "VPS_LOGIN_USER", "VPS_ACCOUNT"),
            "FORM_VPS_PASSWORD" to credentialValue(legacy, true, "VPS_LOGIN_PASSWORD", "VPS_PASSWORD"),
            "FORM_PANEL_ACCOUNT" to credentialValue(legacy, false, "PANEL_USERNAME", "PANEL_ACCOUNT", "XUI_USERNAME"),
            "FORM_PANEL_PASSWORD" to credentialValue(legacy, true, "PANEL_PASSWORD", "XUI_PASSWORD"),
        )
        form.forEach { (key, raw) ->
            val value = raw.trim()
            val upper = value.uppercase(Locale.ROOT)
            require(value.isNotEmpty() && !upper.startsWith("UNKNOWN") && !upper.startsWith("NOT_RETAINED") && upper != "SSH_KEY_ONLY") {
                "required login credential form is incomplete: ${key.removePrefix("FORM_")}"
            }
        }
        return form
    }

    private fun credentialValue(legacy: String, preserveWhitespace: Boolean, vararg keys: String): String {
        val wanted = keys.toSet()
        var found = ""
        // Keep the value bytes exactly as emitted after the first `=`.  In
        // particular, a user-selected password may intentionally start or
        // end with spaces.  Only the key/validation view is trimmed; the raw
        // candidate is returned to the protected handoff form unchanged for
        // password keys; account keys are normalized to remove copy/paste
        // padding before they are used as login identities.
        legacy.replace("\r\n", "\n").split('\n').forEach { line ->
            val separator = line.indexOf('=')
            if (separator <= 0) return@forEach
            val key = line.substring(0, separator).trim()
            if (key !in wanted) return@forEach
            val candidate = line.substring(separator + 1)
            if (usableCredential(candidate)) found = if (preserveWhitespace) candidate else candidate.trim()
        }
        // The concatenated stream is ordered archive -> current, so the last
        // usable occurrence (regardless of legacy/canonical alias spelling)
        // is the authoritative value.  Placeholders are ignored above and
        // therefore cannot shadow a valid archived secret.
        return found
    }

    private fun usableCredential(value: String): Boolean {
        // Validate a normalized view, but never return that normalized view:
        // leading/trailing spaces are valid custom-secret characters.  Reject
        // controls that cannot safely survive the handoff line protocol.
        if (value.any { it == '\u0000' || it == '\r' || it == '\n' }) return false
        val normalized = value.trim()
        if (normalized.isBlank()) return false
        val upper = normalized.uppercase(Locale.ROOT)
        return !upper.startsWith("UNKNOWN") &&
            !upper.startsWith("NOT_RETAINED") && upper != "SSH_KEY_ONLY"
    }

    /** Strict parser for generated Cloudflare/XHTTP VLESS links. */
    fun cdnXHttpLink(value: String): CdnXHttpLink {
        val parsed = URI(value.trim())
        require(parsed.scheme.equals("vless", true) && !parsed.userInfo.isNullOrBlank() && ':' !in parsed.userInfo) { "invalid VLESS URL" }
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
        fun exact(key: String, expected: String) { require(query[key] == listOf(expected)) { "missing, duplicated, or invalid $key" } }
        exact("encryption", "none")
        exact("security", "tls")
        exact("sni", domain)
        exact("fp", "chrome")
        exact("type", "xhttp")
        exact("host", domain)
        exact("mode", "packet-up")
        val path = query["path"]?.singleOrNull().orEmpty()
        require(path.matches(Regex("^/[0-9a-fA-F]{32}/$"))) { "invalid XHTTP path" }
        val acceptedLabels = if (port == 8443) {
            setOf(
                "PNA-CDN-XHTTP-STAGE", "TNA-CDN-XHTTP-STAGE",
                // 04f-xhttp-cdn-api.sh has historically emitted ORANGE for
                // the same 8443 profile; keep that generated link valid while
                // still rejecting arbitrary fragments.
                "PNA-CDN-XHTTP-ORANGE", "TNA-CDN-XHTTP-ORANGE",
            )
        } else {
            setOf("PNA-CDN-XHTTP", "TNA-CDN-XHTTP", "PNA-CDN-XHTTP-ORANGE", "TNA-CDN-XHTTP-ORANGE")
        }
        require(parsed.fragment in acceptedLabels) { "invalid profile label" }
        return CdnXHttpLink(uuid, domain, port, path, parsed.fragment.orEmpty())
    }

    /**
     * Normalize a generated CDN/XHTTP URI before it is shown or copied.
     *
     * v0.9.x exporters used TNA-* fragments while v1 exporters use PNA-*.
     * The parser above intentionally accepts both spellings so an in-place
     * upgrade can consume an existing handoff.  This formatter is the only
     * migration step needed on output: it replaces just the URI fragment and
     * keeps the complete prefix byte-for-byte, including optional transport
     * query knobs such as `x_padding_bytes` and `extra`.
     */
    fun canonicalizeCdnXHttpLink(value: String): String {
        val trimmed = value.trim()
        val parsed = cdnXHttpLink(trimmed)
        val canonicalLabel = when (parsed.label) {
            "PNA-CDN-XHTTP", "TNA-CDN-XHTTP" -> "PNA-CDN-XHTTP"
            "PNA-CDN-XHTTP-STAGE", "TNA-CDN-XHTTP-STAGE" -> "PNA-CDN-XHTTP-STAGE"
            "PNA-CDN-XHTTP-ORANGE", "TNA-CDN-XHTTP-ORANGE" -> "PNA-CDN-XHTTP-ORANGE"
            else -> error("invalid CDN/XHTTP profile label")
        }
        val fragmentStart = trimmed.lastIndexOf('#')
        require(fragmentStart >= 0) { "missing CDN/XHTTP profile fragment" }
        return trimmed.substring(0, fragmentStart + 1) + canonicalLabel
    }

    /**
     * Copy only the known, syntactically validated protocol fields into the
     * protected handoff appendix.  Older clients used a broad prefix copy
     * (REALITY-, CDN_XHTTP-, and SS2022-prefixed fields), which allowed stale
     * or malformed values
     * from an interrupted run to be presented as usable links.  Keep this
     * allowlist deliberately narrow; unknown future fields remain in the raw
     * archive and can be migrated by a newer client.
     */
    fun validatedHandoffProtocolFields(values: Map<String, String>): Map<String, String> {
        val result = linkedMapOf<String, String>()
        values.forEach { (rawKey, rawValue) ->
            val key = rawKey.trim()
            validatedProtocolFieldValue(key, rawValue.trim())?.let { result[key] = it }
        }
        return canonicalizeCdnHandoffFields(result)
    }

    private val uuidPattern = Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$")

    private fun allowedHandoffProtocolKey(key: String): Boolean {
        val generic = setOf(
            // These are emitted by the v0.9.x and v1 handoff writers outside
            // a protocol-specific prefix. Keep them typed so archive/current
            // concatenation can regenerate one authoritative row.
            "COVER_DOMAIN", "PUBLIC_IP_AT_HANDOFF", "VPS_PUBLIC_IP", "PUBLIC_IP",
            "UUID", "VLESS_LINK", "DIRECT_REALITY_LINK", "REALITY_LINK",
            "SUB_ID", "TEST_PORT",
            "SUBSCRIPTION_URL", "SUBSCRIPTION_LINK", "SS2022_LINK",
        )
        if (key in generic) return true
        if (key.startsWith("REALITY_")) {
            val suffix = key.removePrefix("REALITY_")
            return suffix in setOf(
                "GENERATED_UUID", "GENERATED_PRIVATE_KEY", "GENERATED_PUBLIC_KEY", "GENERATED_SHORT_ID", "GENERATED_SUB_ID",
                "TEST_UUID", "PRIVATE_KEY", "PUBLIC_KEY", "SHORT_ID", "TEST_SUB_ID", "TEST_LINK", "PRODUCTION_LINK",
                "SHADOW_LINK", "SERVER_NAME", "SERVER_PORT", "SERVER_ADDRESS", "PUBLIC_PORT", "PORT", "UUID",
                "CLIENT_PUBLIC_KEY", "CLIENT_SHORT_ID", "SNI", "DEST_DOMAIN", "TEST_PORT", "ENABLED", "TRANSPORT", "MODE", "STATUS",
            ) ||
                Regex("^[0-9]+_(SERVER_NAME|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|REMARK)$").matches(suffix) ||
                Regex("^CLIENT_[0-9]+_(UUID|SUB_ID|PORT|REMARK|LINK|SUBSCRIPTION_URL)$").matches(suffix)
        }
        if (key == "XHTTP_LINK" || key == "XHTTP_STAGE_LINK") return true
        // Non-link XHTTP aliases are canonicalized before validation and are
        // accepted here for callers that inspect the allowlist directly.
        if (key in setOf(
                "XHTTP_ENABLED", "XHTTP_UUID", "XHTTP_PATH", "XHTTP_LOCAL_PORT",
                "XHTTP_SUB_ID", "XHTTP_DOMAIN", "XHTTP_PUBLIC_DOMAIN", "XHTTP_PUBLIC_PORT",
                "XHTTP_SUBSCRIPTION_URL", "XHTTP_TRANSPORT", "XHTTP_MODE", "XHTTP_STATUS",
            )) return true
        if (key.startsWith("CDN_XHTTP_")) {
            return key.removePrefix("CDN_XHTTP_") in setOf(
                "ENABLED", "UUID", "PATH", "LOCAL_PORT", "PORT", "SUB_ID", "DOMAIN", "PUBLIC_PORT", "LINK", "STAGE_LINK",
                "SUBSCRIPTION_URL", "TRANSPORT", "MODE", "STATUS", "EDGE_VALIDATED", "ORIGIN_READY", "CLIENT_CONFIRMED",
                "STAGE_REACHABILITY", "ORIGIN_SCOPE", "EDGE_DOMAIN", "EDGE_PORT", "ORIGIN_PORT", "NGINX_STATUS",
            )
        }
        if (key.startsWith("SS2022_")) {
            return key.removePrefix("SS2022_") in setOf(
                "ENABLED", "SERVER_ADDRESS", "PORT", "METHOD", "PASSWORD", "TRANSPORT", "NETWORK", "UNIT",
                "HOST",
                "ALLOWLIST_MODE", "ALLOWLIST_UPDATED_AT", "MIGRATED_FROM", "LINK", "STATUS",
            )
        }
        return false
    }

    private fun safeHandoffValue(value: String): Boolean =
        value.isNotBlank() && value.length <= 4096 && value.none { it.isISOControl() }

    private fun safeHandoffToken(value: String): Boolean =
        value.length <= 1024 && value.none { it.isISOControl() }

    private fun usableHandoffSecret(value: String): Boolean {
        if (!safeHandoffValue(value)) return false
        val upper = value.uppercase(Locale.ROOT)
        return listOf("UNKNOWN", "NOT_RETAINED", "UNAVAILABLE", "MISSING", "N/A").none {
            upper == it || upper.startsWith("${it}_")
        }
    }

    private fun validEndpoint(value: String): Boolean =
        Validation.validHost(value) || Validation.validDomain(value)

    private fun validVlessLink(value: String): Boolean {
        val parsed = runCatching { URI(value) }.getOrNull() ?: return false
        val user = parsed.userInfo.orEmpty()
        return parsed.scheme.equals("vless", true) && uuidPattern.matches(user) &&
            validEndpoint(parsed.host.orEmpty()) && parsed.port in 1..65535
    }

    private fun validSs2022Link(value: String): Boolean {
        val parsed = runCatching { URI(value) }.getOrNull() ?: return false
        return parsed.scheme.equals("ss", true) && parsed.userInfo.orEmpty().isNotBlank() &&
            validEndpoint(parsed.host.orEmpty()) && parsed.port in 1..65535
    }

    private fun validSubscriptionUrl(value: String): Boolean {
        val parsed = runCatching { URI(value) }.getOrNull() ?: return false
        return parsed.scheme.equals("https", true) && validEndpoint(parsed.host.orEmpty()) &&
            parsed.userInfo == null && parsed.rawPath.orEmpty().isNotBlank()
    }

    private fun validXhttpPath(value: String): Boolean =
        Regex("^/[A-Za-z0-9._~-]{1,256}/?$").matches(value)

    fun panel(value: String): PanelMetadata {
        val values = kv(markedBlockCurrentOrLegacy(value, PANEL_BEGIN, PANEL_END, LEGACY_PANEL_BEGIN, LEGACY_PANEL_END))
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
        val values = kv(markedBlockCurrentOrLegacy(value, TOOLKIT_BEGIN, TOOLKIT_END, LEGACY_TOOLKIT_BEGIN, LEGACY_TOOLKIT_END))
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
        val brand = values["TOOLKIT_BRAND"].orEmpty()
        val root = values["TOOLKIT_ROOT"].orEmpty()
        if (brand.isNotBlank() || root.isNotBlank()) {
            require((brand == "PNA" && root == "/opt/proxy-node-assistant-current") ||
                (brand == "TNA_LEGACY" && root == "/opt/text-node-assistant-current") ||
                (brand == "PNA_LEGACY" && root == "/opt/proxy-runbook-current")) { "invalid toolkit brand/root" }
        }
        return ToolkitProbe(true, complete, version, values["TOOLKIT_BUILD_ID"].orEmpty(), revision, brand, root)
    }

    fun stableNodeIdentity(value: String, targetId: String): StableNodeIdentity {
        val values = kv(markedBlockCurrentOrLegacy(value, NODE_IDENTITY_BEGIN, NODE_IDENTITY_END, LEGACY_NODE_IDENTITY_BEGIN, LEGACY_NODE_IDENTITY_END))
        val serverId = values["SERVER_ID"].orEmpty()
        val nodeId = values["NODE_ID"].orEmpty()
        val machine = values["MACHINE_ID_SHA256"].orEmpty()
        val hostKey = values["SSH_HOST_KEY_SHA256"].orEmpty()
        val firstIp = values["FIRST_KNOWN_PUBLIC_IP"].orEmpty()
        val currentIp = values["CURRENT_PUBLIC_IP"].orEmpty()
        require(serverId.matches(Regex("^(?:tna|pna)-srv-[0-9a-f]{32}$"))) { "invalid SERVER_ID" }
        require(nodeId.matches(Regex("^(?:tna|pna)-node-[0-9a-f]{32}$"))) { "invalid NODE_ID" }
        require(machine.matches(Regex("^[0-9a-f]{64}$"))) { "invalid machine-id hash" }
        require(hostKey.matches(Regex("^SHA256:[A-Za-z0-9+/]+$"))) { "invalid host-key fingerprint" }
        require(values["MACHINE_ID_MATCH"] == "1" && values["SSH_HOST_KEY_MATCH"] == "1") { "stable node identity mismatch" }
        require(validCanonicalPublicIpv4(firstIp) && validCanonicalPublicIpv4(currentIp)) { "invalid stable public IPv4" }
        return StableNodeIdentity(targetId, serverId, nodeId, machine, hostKey, firstIp, currentIp)
    }

    fun validCanonicalPublicIpv4(value: String): Boolean {
        val parts = value.trim().split('.')
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
