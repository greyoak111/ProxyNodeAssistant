package com.proxynodeassistant.android.remote

import com.proxynodeassistant.android.core.Validation
import java.security.SecureRandom

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
) {
    fun validate(existingNode: Boolean) {
        require(existingNode || routeMode != InstallRouteMode.KEEP) { "keep requires an existing node" }
        require(coverChoice == "preserve" || coverChoice == "random" || coverChoice == "auto" || coverChoice.toIntOrNull()?.let { it in 1..15 } == true) {
            "invalid cover choice"
        }
        require(existingNode || coverChoice != "preserve") { "fresh install cannot preserve a cover template" }
        require(existingNode || performanceMode != InstallPerformanceMode.PRESERVE) { "fresh install cannot preserve performance" }
        require(existingNode || warpMode != InstallWarpMode.PRESERVE) { "fresh install cannot preserve WARP" }
        if (routeMode == InstallRouteMode.GRAY || routeMode == InstallRouteMode.DUAL) validateIdentity(gray, "gray")
        if (routeMode == InstallRouteMode.ORANGE || routeMode == InstallRouteMode.DUAL) validateIdentity(orange, "orange")
        require(routeMode != InstallRouteMode.DUAL || !gray.domain.equals(orange.domain, ignoreCase = true)) {
            "dual route requires different hostnames"
        }
    }

    fun reviewLines(): List<String> = buildList {
        add("ROUTE_MODE=${routeMode.wireValue}")
        add("COVER_CHOICE=$coverChoice")
        add("PERFORMANCE=${performanceMode.wireValue}")
        add("WARP_MODE=${warpMode.wireValue}")
        add("BACKUP_BEFORE_CHANGE=true")
        add("PRUNE_AFTER_SUCCESS=$pruneAfterSuccess")
        add("OPEN_PANEL_ON_SUCCESS=$openPanelOnSuccess")
        add("PORT_PRESET=reality:443 shadow:24443 cdn:8443 warp:40000")
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
