package com.proxynodeassistant.android.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallPlanTest {
    @Test
    fun freshPlanRejectsKeepAndPreserveModes() {
        val plan = AndroidInstallPlan(
            routeMode = InstallRouteMode.KEEP,
            coverChoice = "preserve",
            performanceMode = InstallPerformanceMode.PRESERVE,
            warpMode = InstallWarpMode.PRESERVE,
            pruneAfterSuccess = false,
            openPanelOnSuccess = false,
        )
        assertThrows(IllegalArgumentException::class.java) { plan.validate(existingNode = false) }
    }

    @Test
    fun explicitGrayFreshPlanUsesFixedPortsAndNoAssumeDefaults() {
        val plan = AndroidInstallPlan(
            routeMode = InstallRouteMode.GRAY,
            coverChoice = "7",
            performanceMode = InstallPerformanceMode.AUTO,
            warpMode = InstallWarpMode.ENSURE_ON,
            gray = InstallRouteIdentity("cover.example.com", "owner@example.com"),
            pruneAfterSuccess = true,
            openPanelOnSuccess = true,
        )
        plan.validate(existingNode = false)
        val env = plan.environmentValues("root", "zh", "/tmp/proxy-node-assistant-auto-input-0123456789abcdef01234567.env")
        assertEquals("gray", env["TNA_ROUTE_MODE"])
        assertEquals("443", env["TNA_REALITY_PRODUCTION_PORT"])
        assertEquals("24443", env["TNA_REALITY_SHADOW_PORT"])
        assertEquals("8443", env["TNA_CDN_ORIGIN_PORT"])
        assertEquals("40000", env["TNA_WARP_LOOPBACK_PORT"])
        assertEquals("32443", env["PNA_SS2022_PORT"])
        assertEquals("1", env["TNA_PLAN_CONFIRMED"])
        assertFalse(env.containsKey("PROXY_RUNBOOK_ASSUME_DEFAULTS"))
        assertFalse(env.values.any { it == "/tmp/proxy-runbook-auto-input" })
    }

    @Test
    fun dualPlanRequiresDifferentValidHostnames() {
        val plan = AndroidInstallPlan(
            routeMode = InstallRouteMode.DUAL,
            coverChoice = "random",
            performanceMode = InstallPerformanceMode.STANDARD,
            warpMode = InstallWarpMode.ENSURE_ON,
            gray = InstallRouteIdentity("same.example.com", "gray@example.com"),
            orange = InstallRouteIdentity("SAME.example.com", "orange@example.com"),
            pruneAfterSuccess = false,
            openPanelOnSuccess = false,
        )
        assertThrows(IllegalArgumentException::class.java) { plan.validate(existingNode = true) }
    }

    @Test
    fun previewMasksEmailButShowsExplicitChoices() {
        val plan = AndroidInstallPlan(
            routeMode = InstallRouteMode.ORANGE,
            coverChoice = "auto",
            performanceMode = InstallPerformanceMode.HIGH,
            warpMode = InstallWarpMode.ENSURE_ON,
            orange = InstallRouteIdentity("www.example.com", "private.owner@example.com"),
            pruneAfterSuccess = false,
            openPanelOnSuccess = true,
        )
        plan.validate(existingNode = false)
        val review = plan.reviewLines().joinToString("\n")
        assertTrue("ORANGE_EMAIL=p***@example.com" in review)
        assertFalse("private.owner@example.com" in review)
        assertTrue("PORT_PRESET=reality:443 shadow:24443 cdn:8443 warp:40000 ss2022:32443/tcp" in review)
        assertTrue("SS2022_PORT_POLICY=formal:32443; existing-trial:30443" in review)
        assertTrue("SS2022_ALLOWLIST=exact-public-ip; use action 19 for local-IP add or action 24 for manual management" in review)
    }

    @Test
    fun formalPortIsDefaultAndExistingTrialPortRemainsValid() {
        val fresh = AndroidInstallPlan(
            routeMode = InstallRouteMode.GRAY,
            coverChoice = "1",
            performanceMode = InstallPerformanceMode.AUTO,
            warpMode = InstallWarpMode.ENSURE_ON,
            gray = InstallRouteIdentity("cover.example.com", "owner@example.com"),
            pruneAfterSuccess = false,
            openPanelOnSuccess = false,
        )
        assertEquals(Ss2022PortPolicy.FORMAL_PORT, fresh.ss2022Port)
        fresh.validate(existingNode = false)

        val existingTrial = fresh.copy(ss2022Port = Ss2022PortPolicy.TRIAL_PORT)
        existingTrial.validate(existingNode = true)
        assertEquals("30443", existingTrial.environmentValues("root", "zh", "/tmp/input.env")["PNA_SS2022_PORT"])
        assertThrows(IllegalArgumentException::class.java) { existingTrial.validate(existingNode = false) }
    }

    @Test
    fun ss2022PortMustBeDedicatedTcpPort() {
        val conflicting = AndroidInstallPlan(
            routeMode = InstallRouteMode.GRAY,
            coverChoice = "1",
            performanceMode = InstallPerformanceMode.AUTO,
            warpMode = InstallWarpMode.ENSURE_ON,
            gray = InstallRouteIdentity("cover.example.com", "owner@example.com"),
            pruneAfterSuccess = false,
            openPanelOnSuccess = false,
            ss2022Port = 443,
        )
        assertThrows(IllegalArgumentException::class.java) { conflicting.validate(existingNode = false) }
    }

    @Test
    fun oneRunTokensAreRandomAndPathSafe() {
        val first = newOneRunToken()
        val second = newOneRunToken()
        assertTrue(first.matches(Regex("^[0-9a-f]{24}$")))
        assertTrue(second.matches(Regex("^[0-9a-f]{24}$")))
        assertNotEquals(first, second)
    }
}
