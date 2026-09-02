package com.proxynodeassistant.android.remote

import com.proxynodeassistant.android.core.Validation
import java.security.SecureRandom

/**
 * SS2022 port policy shared by the Android planner and diagnostics.
 *
 * 32443 is the v1 formal listener for fresh installs. 30443 remains a
 * compatibility value for nodes that already have the short-lived trial
 * listener; callers must preserve a discovered existing value rather than
 * silently moving that listener during an upgrade.
 */
internal object Ss2022PortPolicy {
    const val FORMAL_PORT = 32443
    const val TRIAL_PORT = 30443

    fun valid(port: Int): Boolean = port in 1024..65535 && port !in setOf(443, 24443, 8443, 40000)
}

internal enum class InstallRouteMode(val wireValue: String) {
    KEEP("keep"),
    GRAY("gray"),
    ORANGE("orange"),
    DUAL("dual"),
}

internal enum class InstallPerformanceMode(val wireValue: String) {
    PRESERVE("preserve"),
    AUTO("auto"),
    LOW("low"),
    STANDARD("standard"),
    HIGH("high"),
}

internal enum class InstallWarpMode(val wireValue: String) {
    PRESERVE("preserve"),
    ENSURE_ON("ensure-on"),
}

/**
 * How install/upgrade obtains the two remote login credential pairs.
 *
 * Values are deliberately limited to the strings consumed by the runbook.
 * Secret fields in [AndroidCredentialPlan] are ephemeral and are never part
 * of a review line, environment value, or persisted preference.
 */
internal enum class InstallCredentialMode(val wireValue: String) {
    PRESERVE("preserve"),
    RANDOM("random"),
    CUSTOM("custom"),
}

internal data class AndroidCredentialPlan(
    val vpsMode: InstallCredentialMode = InstallCredentialMode.RANDOM,
    val vpsPassword: String = "",
    val panelMode: InstallCredentialMode = InstallCredentialMode.RANDOM,
    val panelAccount: String = "",
    val panelPassword: String = "",
) {
    /** Validate policy without ever printing the secret values. */
    fun validate(existingNode: Boolean) {
        if (!existingNode) {
            require(vpsMode != InstallCredentialMode.PRESERVE) { "fresh install cannot preserve VPS credentials" }
            require(panelMode != InstallCredentialMode.PRESERVE) { "fresh install cannot preserve panel credentials" }
        }
        if (vpsMode == InstallCredentialMode.CUSTOM) {
            require(validSecret(vpsPassword)) { "custom VPS password must be 8..256 characters without NUL/CR/LF" }
        }
        if (panelMode == InstallCredentialMode.CUSTOM) {
            require(validPanelAccount(panelAccount)) { "custom panel account has invalid characters" }
            require(validSecret(panelPassword)) { "custom panel password must be 8..256 characters without NUL/CR/LF" }
        }
    }

    /** Safe mode/account summary for the final install review. */
    fun reviewLines(): List<String> = buildList {
        add("VPS_CREDENTIAL_MODE=${vpsMode.wireValue}")
        add("PANEL_CREDENTIAL_MODE=${panelMode.wireValue}")
        if (panelMode == InstallCredentialMode.CUSTOM) add("PANEL_ACCOUNT=$panelAccount")
    }

    companion object {
        private val panelAccountPattern = Regex("^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")

        fun validPanelAccount(value: String): Boolean = panelAccountPattern.matches(value)

        /** Keep spaces meaningful; reject empty values and shell/control delimiters. */
        fun validSecret(value: String): Boolean =
            value.length in 8..256 && value.isNotEmpty() &&
                !value.contains('\u0000') && !value.contains('\r') && !value.contains('\n')
    }
}

internal data class InstallRouteIdentity(
    val domain: String = "",
    val email: String = "",
)

internal data class AndroidInstallPlan(
    val routeMode: InstallRouteMode,
    val coverChoice: String,
    val performanceMode: InstallPerformanceMode,
    val warpMode: InstallWarpMode,
    val gray: InstallRouteIdentity = InstallRouteIdentity(),
    val orange: InstallRouteIdentity = InstallRouteIdentity(),
    val pruneAfterSuccess: Boolean,
    val openPanelOnSuccess: Boolean,
    /** TCP-only Shadowsocks 2022 listener. Fresh installs use the formal port. */
    val ss2022Port: Int = Ss2022PortPolicy.FORMAL_PORT,
    /** Ephemeral VPS/panel credential policy for this run. */
    val credentials: AndroidCredentialPlan = AndroidCredentialPlan(),
) {
    fun validate(existingNode: Boolean) {
        require(existingNode || routeMode != InstallRouteMode.KEEP) { "keep requires an existing node" }
        require(coverChoice == "preserve" || coverChoice == "random" || coverChoice == "auto" || coverChoice.toIntOrNull()?.let { it in 1..15 } == true) {
            "invalid cover choice"
        }
        require(existingNode || coverChoice != "preserve") { "fresh install cannot preserve a cover template" }
        require(existingNode || performanceMode != InstallPerformanceMode.PRESERVE) { "fresh install cannot preserve performance" }
        require(existingNode || warpMode != InstallWarpMode.PRESERVE) { "fresh install cannot preserve WARP" }
        require(Ss2022PortPolicy.valid(ss2022Port)) { "SS2022 port must be a dedicated TCP port between 1024 and 65535" }
        require(existingNode || ss2022Port != Ss2022PortPolicy.TRIAL_PORT) {
            "30443 is reserved for an existing SS2022 trial/migration; fresh nodes must use the formal port or another dedicated port"
        }
        if (routeMode == InstallRouteMode.GRAY || routeMode == InstallRouteMode.DUAL) validateIdentity(gray, "gray")
        if (routeMode == InstallRouteMode.ORANGE || routeMode == InstallRouteMode.DUAL) validateIdentity(orange, "orange")
        require(routeMode != InstallRouteMode.DUAL || !gray.domain.equals(orange.domain, ignoreCase = true)) {
            "dual route requires different hostnames"
        }
        credentials.validate(existingNode)
    }

    fun reviewLines(): List<String> = buildList {
        add("ROUTE_MODE=${routeMode.wireValue}")
        add("COVER_CHOICE=$coverChoice")
        add("PERFORMANCE=${performanceMode.wireValue}")
        add("WARP_MODE=${warpMode.wireValue}")
        add("BACKUP_BEFORE_CHANGE=true")
        add("PRUNE_AFTER_SUCCESS=$pruneAfterSuccess")
        add("OPEN_PANEL_ON_SUCCESS=$openPanelOnSuccess")
        add("PORT_PRESET=reality:443 shadow:24443 cdn:8443 warp:40000 ss2022:$ss2022Port/tcp")
        add("SS2022_PORT_POLICY=formal:${Ss2022PortPolicy.FORMAL_PORT}; existing-trial:${Ss2022PortPolicy.TRIAL_PORT}")
        add("SS2022_NETWORK=tcp-only")
        add("SS2022_ALLOWLIST=exact-public-ip; use action 19 for local-IP add or action 24 for manual management")
        addAll(credentials.reviewLines())
        if (routeMode == InstallRouteMode.GRAY || routeMode == InstallRouteMode.DUAL) {
            add("GRAY_DOMAIN=${gray.domain}")
            add("GRAY_EMAIL=${maskEmail(gray.email)}")
        }
        if (routeMode == InstallRouteMode.ORANGE || routeMode == InstallRouteMode.DUAL) {
            add("ORANGE_DOMAIN=${orange.domain}")
            add("ORANGE_EMAIL=${maskEmail(orange.email)}")
        }
    }.sorted()

    fun environmentValues(loginUser: String, language: String, inputPath: String): Map<String, String> = linkedMapOf(
        "PROXY_RUNBOOK_LOGIN_USER" to loginUser,
        "PROXY_RUNBOOK_SSH_KEY_INSTALLED" to "1",
        "PROXY_RUNBOOK_GUI_MODE" to "1",
        "PROXY_RUNBOOK_LANG" to language,
        "TNA_ROUTE_MODE" to routeMode.wireValue,
        "TNA_PERFORMANCE_MODE" to performanceMode.wireValue,
        "TNA_WARP_MODE" to warpMode.wireValue,
        "TNA_COVER_TEMPLATE" to coverChoice,
        "TNA_REALITY_PRODUCTION_PORT" to "443",
        "TNA_REALITY_SHADOW_PORT" to "24443",
        "TNA_CDN_ORIGIN_PORT" to "8443",
        "TNA_WARP_LOOPBACK_PORT" to "40000",
        "PNA_SS2022_PORT" to ss2022Port.toString(),
        "TNA_VPS_PASSWORD_MODE" to credentials.vpsMode.wireValue,
        "TNA_PANEL_CREDENTIAL_MODE" to credentials.panelMode.wireValue,
        "TNA_PLAN_CONFIRMED" to "1",
        "TNA_AUTO_INPUT" to inputPath,
    )

    private fun validateIdentity(identity: InstallRouteIdentity, label: String) {
        require(Validation.validDomain(identity.domain)) { "$label domain invalid" }
        require(Validation.validEmail(identity.email)) { "$label email invalid" }
    }

    companion object {
        fun maskEmail(value: String): String {
            val parts = value.trim().split('@', limit = 2)
            return if (parts.size == 2 && parts[0].isNotEmpty()) "${parts[0].first()}***@${parts[1]}" else "***"
        }
    }
}

internal fun newOneRunToken(random: SecureRandom = SecureRandom()): String =
    ByteArray(12).also(random::nextBytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
