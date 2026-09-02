package com.proxynodeassistant.android.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolParsersTest {
    @Test fun markedBlockMatchesTheOuterEndForNestedSameNameMarkers() {
        val value = """
            noise
            BEGIN
            outer-before
            BEGIN
            inner-payload
            END
            outer-after
            END
            trailing
        """.trimIndent()
        assertEquals(
            "outer-before\nBEGIN\ninner-payload\nEND\nouter-after",
            ProtocolParsers.markedBlock(value, "BEGIN", "END"),
        )
    }

    @Test fun markedBlockRejectsAnUnclosedNestedMarker() {
        val value = """
            BEGIN
            outer-before
            BEGIN
            inner-payload
            END
        """.trimIndent()
        assertThrows(IllegalArgumentException::class.java) {
            ProtocolParsers.markedBlock(value, "BEGIN", "END")
        }
    }

    @Test fun connectionClosedCannotBecomeHandoff() {
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.handoff("Connection to example.invalid closed.") }
    }

    @Test fun emptyMarkedHandoffIsRejected() {
        val value = "${ProtocolParsers.HANDOFF_BEGIN}\n${ProtocolParsers.HANDOFF_END}\n"
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.handoff(value) }
    }

    @Test fun runMarkerWithoutUsefulFieldsIsRejected() {
        val value = "${ProtocolParsers.HANDOFF_BEGIN}\nHANDOFF_RUN_STARTED=20260823-010203\n${ProtocolParsers.HANDOFF_END}\n"
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.handoff(value) }
    }

    @Test fun validHandoffSurvivesAnsiAndNoise() {
        val value = "noise\n\u001B[33m${ProtocolParsers.HANDOFF_BEGIN}\u001B[0m\nHANDOFF_RUN_STARTED=run-1\nPANEL_PORT=2053\nPANEL_USERNAME=operator\n${ProtocolParsers.HANDOFF_END}\nConnection closed."
        val parsed = ProtocolParsers.handoff(value)
        assertTrue(parsed.contains("PANEL_PORT=2053"))
        assertFalse(parsed.contains("Connection closed"))
    }

    @Test fun legacyTnaHandoffMarkersRemainReadableDuringUpgrade() {
        val value = "noise\n__TNA_HANDOFF_BEGIN__\nHANDOFF_RUN_STARTED=legacy-run\nVPS_LOGIN_USER=root\nVPS_LOGIN_PASSWORD=not-a-real-secret\n__TNA_HANDOFF_END__"
        assertTrue(ProtocolParsers.handoff(value).contains("VPS_LOGIN_USER=root"))
    }

    @Test fun legacyCredentialAliasOnlyHandoffIsAcceptedAsUseful() {
        val value = "${ProtocolParsers.HANDOFF_BEGIN}\nHANDOFF_RUN_STARTED=legacy-alias\nXUI_USERNAME=legacy-panel\n${ProtocolParsers.HANDOFF_END}"
        assertTrue(ProtocolParsers.handoff(value).contains("XUI_USERNAME=legacy-panel"))
    }

    @Test fun credentialReadinessAcceptsOnlyCompletePresenceBits() {
        val value = """
            noise
            ${ProtocolParsers.CREDENTIAL_READINESS_BEGIN}
            VPS_LOGIN_USER_PRESENT=1
            VPS_LOGIN_PASSWORD_PRESENT=1
            PANEL_USERNAME_PRESENT=1
            PANEL_PASSWORD_PRESENT=1
            COMPLETE=1
            SOURCE=handoff
            ${ProtocolParsers.CREDENTIAL_READINESS_END}
        """.trimIndent()
        val readiness = ProtocolParsers.credentialReadiness(value)
        assertTrue(readiness.isComplete)
        assertEquals("handoff", readiness.source)
        assertEquals("VPS user=present, VPS password=present, panel user=present, panel password=present", readiness.summary())
    }

    @Test fun credentialReadinessNormalizesTrimmedAndCaseVariantKeys() {
        val value = """
            noise
            ${ProtocolParsers.CREDENTIAL_READINESS_BEGIN}
              vps_login_user_present = 1
              VPS_LOGIN_PASSWORD_PRESENT = 1
              panel_username_present = 1
              panel_password_present = 1
              complete = 1
              source = android-readiness
            ${ProtocolParsers.CREDENTIAL_READINESS_END}
        """.trimIndent()
        val readiness = ProtocolParsers.credentialReadiness(value)
        assertTrue(readiness.isComplete)
        assertEquals("android-readiness", readiness.source)
    }

    @Test fun credentialReadinessRejectsSecretBearingOrInconsistentPayloads() {
        val secret = "password-must-never-cross-preflight"
        val withSecret = """
            ${ProtocolParsers.CREDENTIAL_READINESS_BEGIN}
            VPS_LOGIN_USER_PRESENT=1
            VPS_LOGIN_PASSWORD_PRESENT=1
            PANEL_USERNAME_PRESENT=1
            PANEL_PASSWORD_PRESENT=1
            COMPLETE=1
            PANEL_PASSWORD=$secret
            SOURCE=handoff
            ${ProtocolParsers.CREDENTIAL_READINESS_END}
        """.trimIndent()
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.credentialReadiness(withSecret) }

        val inconsistent = """
            ${ProtocolParsers.CREDENTIAL_READINESS_BEGIN}
            VPS_LOGIN_USER_PRESENT=1
            VPS_LOGIN_PASSWORD_PRESENT=0
            PANEL_USERNAME_PRESENT=1
            PANEL_PASSWORD_PRESENT=1
            COMPLETE=1
            SOURCE=handoff
            ${ProtocolParsers.CREDENTIAL_READINESS_END}
        """.trimIndent()
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.credentialReadiness(inconsistent) }
    }

    @Test fun ss2022OnlyHandoffIsAcceptedAsUsefulRuntimeData() {
        val value = "${ProtocolParsers.HANDOFF_BEGIN}\nHANDOFF_RUN_STARTED=run-ss\nSS2022_LINK=ss://redacted@203.0.113.10:30443#ProxyNodeAssistant-SS2022-TCP\nSS2022_PORT=30443\n${ProtocolParsers.HANDOFF_END}"
        assertTrue(ProtocolParsers.handoff(value).contains("SS2022_PORT=30443"))
    }

    @Test fun dynamicRealityProductionLinkCountsAsUsefulHandoffData() {
        val value = "${ProtocolParsers.HANDOFF_BEGIN}\nHANDOFF_RUN_STARTED=run-reality\nREALITY_PRODUCTION_LINK=vless://redacted@example.com:443?security=reality#production\n${ProtocolParsers.HANDOFF_END}"
        assertTrue(ProtocolParsers.handoff(value).contains("REALITY_PRODUCTION_LINK="))
    }

    @Test fun panelRequiresRealPortAndSafePath() {
        val emptyPort = "${ProtocolParsers.PANEL_BEGIN}\nPANEL_PORT=\nWEB_BASE_PATH=/safe/\n${ProtocolParsers.PANEL_END}"
        assertThrows(IllegalStateException::class.java) { ProtocolParsers.panel(emptyPort) }
        val unsafePath = "${ProtocolParsers.PANEL_BEGIN}\nPANEL_PORT=12345\nWEB_BASE_PATH=/safe/?x=1\n${ProtocolParsers.PANEL_END}"
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.panel(unsafePath) }
        val valid = "${ProtocolParsers.PANEL_BEGIN}\nPANEL_PORT=12345\nWEB_BASE_PATH=admin\nPANEL_METADATA_SOURCE=x-ui\n${ProtocolParsers.PANEL_END}"
        assertEquals(12345, ProtocolParsers.panel(valid).port)
        assertEquals("/admin/", ProtocolParsers.panel(valid).path)
    }

    @Test fun toolkitProbeAndVersionComparisonAreStrict() {
        val value = "${ProtocolParsers.TOOLKIT_BEGIN}\nTOOLKIT_PRESENT=1\nTOOLKIT_VERSION=v1.0.0\nTOOLKIT_BUILD_ID=20260901-v100-ss2022-r107\nTOOLKIT_BUILD_REVISION=107\nTOOLKIT_COMPLETE=1\n${ProtocolParsers.TOOLKIT_END}"
        val probe = ProtocolParsers.toolkit(value)
        assertTrue(probe.installed)
        assertTrue(probe.complete)
        assertEquals(107, probe.buildRevision)
        assertTrue(ProtocolParsers.compareVersions("0.10.0", "0.9.9") > 0)
        assertEquals(0, ProtocolParsers.compareVersions("v0.9", "0.9.0"))
    }

    @Test fun sameVersionIncompleteToolkitRepairAllowsInterruptedUploadOnly() {
        fun probe(
            complete: Boolean = false,
            version: String = WorkflowRunner.VERSION,
            buildId: String = "",
            revision: Int = 0,
        ) = com.proxynodeassistant.android.model.ToolkitProbe(
            installed = true,
            complete = complete,
            version = version,
            buildId = buildId,
            buildRevision = revision,
        )

        assertTrue(WorkflowRunner.sameVersionIncompleteRepairAllowed(probe()))
        assertTrue(
            WorkflowRunner.sameVersionIncompleteRepairAllowed(
                probe(buildId = "older-build", revision = WorkflowRunner.BUILD_REVISION - 1),
            ),
        )
        assertTrue(
            WorkflowRunner.sameVersionIncompleteRepairAllowed(
                probe(buildId = WorkflowRunner.BUILD_ID, revision = WorkflowRunner.BUILD_REVISION),
            ),
        )
        assertFalse(
            WorkflowRunner.sameVersionIncompleteRepairAllowed(
                probe(buildId = "future-build", revision = WorkflowRunner.BUILD_REVISION + 1),
            ),
        )
        assertFalse(
            WorkflowRunner.sameVersionIncompleteRepairAllowed(
                probe(buildId = "different-build", revision = WorkflowRunner.BUILD_REVISION),
            ),
        )
        assertFalse(
            WorkflowRunner.sameVersionIncompleteRepairAllowed(
                probe(buildId = "", revision = WorkflowRunner.BUILD_REVISION),
            ),
        )
        assertFalse(
            WorkflowRunner.sameVersionIncompleteRepairAllowed(
                probe(complete = true, buildId = WorkflowRunner.BUILD_ID, revision = WorkflowRunner.BUILD_REVISION),
            ),
        )
        assertFalse(WorkflowRunner.sameVersionIncompleteRepairAllowed(probe(version = "0.9.5")))
    }

    @Test fun sameVersionRefreshUsesToolkitOnlyPathAndNeverTreatsLegacyVersionAsIt() {
        fun probe(
            complete: Boolean = true,
            version: String = WorkflowRunner.VERSION,
            buildId: String = "older-build",
            revision: Int = WorkflowRunner.BUILD_REVISION - 1,
        ) = com.proxynodeassistant.android.model.ToolkitProbe(
            installed = true,
            complete = complete,
            version = version,
            buildId = buildId,
            buildRevision = revision,
        )

        assertTrue(WorkflowRunner.sameVersionToolkitOnlyUpdateRequired(probe()))
        assertTrue(
            WorkflowRunner.sameVersionToolkitOnlyUpdateRequired(
                probe(complete = false, buildId = "", revision = 0),
            ),
        )
        assertFalse(
            WorkflowRunner.sameVersionToolkitOnlyUpdateRequired(
                probe(buildId = WorkflowRunner.BUILD_ID, revision = WorkflowRunner.BUILD_REVISION),
            ),
        )
        assertFalse(
            WorkflowRunner.sameVersionToolkitOnlyUpdateRequired(
                probe(buildId = "future-build", revision = WorkflowRunner.BUILD_REVISION + 1),
            ),
        )
        // A complete probe at the current revision without the exact build ID
        // is ambiguous metadata.  It must not be mistaken for an older
        // package-only refresh (the deploy guard rejects it fail-closed).
        assertFalse(
            WorkflowRunner.sameVersionToolkitOnlyUpdateRequired(
                probe(buildId = "", revision = WorkflowRunner.BUILD_REVISION),
            ),
        )
        assertFalse(
            WorkflowRunner.sameVersionToolkitOnlyUpdateRequired(
                probe(version = "0.9.5"),
            ),
        )
    }

    @Test fun completeHandoffIncludesAllLoginFieldsButNotFormAliases() {
        val legacy = "${ProtocolParsers.HANDOFF_BEGIN}\nHANDOFF_RUN_STARTED=run-credentials\nVPS_LOGIN_USER=root\nVPS_LOGIN_PASSWORD=vps-secret\nPANEL_USERNAME=operator\nPANEL_PASSWORD=panel-secret\nPANEL_PORT=60039\n${ProtocolParsers.HANDOFF_END}"
        val base = ProtocolParsers.handoff(legacy)
        val fields = mapOf(
            "FORM_VPS_ACCOUNT" to "root",
            "FORM_VPS_PASSWORD" to "vps-secret",
            "FORM_PANEL_ACCOUNT" to "operator",
            "FORM_PANEL_PASSWORD" to "panel-secret",
            "PNA_VERSION" to "1.0.0",
        )
        val completed = ProtocolParsers.completeHandoff(base, fields)
        assertTrue(completed.contains("VPS_ACCOUNT=root"))
        assertTrue(completed.contains("PANEL_PASSWORD=panel-secret"))
        assertTrue(completed.contains("PNA_VERSION=1.0.0"))
        assertFalse(completed.contains("FORM_VPS_ACCOUNT="))
        assertFalse(completed.contains("VPS_LOGIN_USER="))
        assertFalse(completed.contains("VPS_LOGIN_PASSWORD="))
        assertFalse(completed.contains("PANEL_USERNAME="))
        assertEquals(1, completed.windowed("VPS_ACCOUNT=root\n".length, 1).count { it == "VPS_ACCOUNT=root\n" })
        assertEquals(1, completed.windowed("PANEL_PASSWORD=panel-secret\n".length, 1).count { it == "PANEL_PASSWORD=panel-secret\n" })
    }

    @Test fun completeHandoffRemovesRetiredLegacyWrapperAndFields() {
        val retiredDriveValue = "co" + "pyparty"
        val retiredHeader = "===== " + "TNA COMPLETE HANDOFF v0.9.5" + " ====="
        val retiredFooter = "===== END " + "TNA COMPLETE HANDOFF v0.9.5" + " ====="
        val legacy = """
            HANDOFF_RUN_STARTED=legacy-run
            VPS_LOGIN_USER=root
            VPS_LOGIN_PASSWORD=vps-secret
            PANEL_USERNAME=operator
            PANEL_PASSWORD=panel-secret
            PNA_VERSION=0.9.5
            PRIVATE_DRIVE_MODE=$retiredDriveValue
            DRIVE_ADMIN_USERNAME=old-admin
            CURRENT_DEVICE_ID=old-device
            CONTROLLER_ACTIVE_COUNT=1
            FUTURE_UNKNOWN_FIELD=preserve-me
            $retiredHeader
            $retiredFooter
        """.trimIndent()
        val completed = ProtocolParsers.completeHandoff(
            legacy,
            mapOf(
                "PNA_VERSION" to "1.0.0",
                "FORM_VPS_ACCOUNT" to "root",
                "FORM_VPS_PASSWORD" to "vps-secret",
                "FORM_PANEL_ACCOUNT" to "operator",
                "FORM_PANEL_PASSWORD" to "panel-secret",
            ),
        )
        assertFalse(completed.contains("TNA COMPLETE HANDOFF " + "v0.9.5"))
        assertFalse(completed.contains("PRIVATE_DRIVE_"))
        assertFalse(completed.contains("DRIVE_ADMIN_"))
        assertFalse(completed.contains("CURRENT_DEVICE_ID="))
        assertFalse(completed.contains("CONTROLLER_ACTIVE_COUNT="))
        assertTrue(completed.contains("FUTURE_UNKNOWN_FIELD=preserve-me"))
        fun occurrences(text: String, needle: String): Int =
            text.windowed(needle.length, 1).count { it == needle }
        assertEquals(1, occurrences(completed, "===== PROXYNODEASSISTANT COMPLETE HANDOFF v1.0.0 ====="))
        assertEquals(1, occurrences(completed, "===== END PROXYNODEASSISTANT COMPLETE HANDOFF v1.0.0 ====="))
    }

    @Test fun loginCredentialFormRejectsPartialLegacyHandoff() {
        val partial = "${ProtocolParsers.HANDOFF_BEGIN}\nHANDOFF_RUN_STARTED=run-partial\nPANEL_PORT=60039\nPANEL_USERNAME=operator\n${ProtocolParsers.HANDOFF_END}"
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.loginCredentialForm(ProtocolParsers.handoff(partial)) }
    }

    @Test fun loginCredentialFormRecoversUsableArchivedValuesAfterPlaceholders() {
        val payload = """
            HANDOFF_RUN_STARTED=archive
            VPS_LOGIN_USER=root
            VPS_LOGIN_PASSWORD=archived-vps-password
            PANEL_USERNAME=operator
            PANEL_PASSWORD=archived-panel-password
            HANDOFF_RUN_STARTED=current
            VPS_LOGIN_PASSWORD=UNKNOWN_NOT_RETAINED
            PANEL_PASSWORD=NOT_RETAINED_BY_APPLICATION
        """.trimIndent()
        val form = ProtocolParsers.loginCredentialForm(payload)
        assertEquals("root", form.getValue("FORM_VPS_ACCOUNT"))
        assertEquals("archived-vps-password", form.getValue("FORM_VPS_PASSWORD"))
        assertEquals("operator", form.getValue("FORM_PANEL_ACCOUNT"))
        assertEquals("archived-panel-password", form.getValue("FORM_PANEL_PASSWORD"))
    }

    @Test fun loginCredentialFormAcceptsLegacyXuiAliases() {
        val payload = """
            HANDOFF_RUN_STARTED=legacy-aliases
            VPS_ACCOUNT=legacy-root
            VPS_PASSWORD=legacy-vps-password
            XUI_USERNAME=legacy-panel
            XUI_PASSWORD=legacy-panel-password
        """.trimIndent()
        val form = ProtocolParsers.loginCredentialForm(payload)
        assertEquals("legacy-root", form.getValue("FORM_VPS_ACCOUNT"))
        assertEquals("legacy-panel", form.getValue("FORM_PANEL_ACCOUNT"))
        assertEquals("legacy-panel-password", form.getValue("FORM_PANEL_PASSWORD"))
    }

    @Test fun loginCredentialFormAcceptsPresentationFormAliases() {
        val payload = """
            ${ProtocolParsers.HANDOFF_BEGIN}
            HANDOFF_RUN_STARTED=presentation-aliases
            FORM_VPS_ACCOUNT=form-root
            FORM_VPS_PASSWORD=form-vps-password
            FORM_PANEL_ACCOUNT=form-panel
            FORM_PANEL_PASSWORD=form-panel-password
            ${ProtocolParsers.HANDOFF_END}
        """.trimIndent()
        val form = ProtocolParsers.loginCredentialForm(ProtocolParsers.handoff(payload))
        assertEquals("form-root", form.getValue("FORM_VPS_ACCOUNT"))
        assertEquals("form-vps-password", form.getValue("FORM_VPS_PASSWORD"))
        assertEquals("form-panel", form.getValue("FORM_PANEL_ACCOUNT"))
        assertEquals("form-panel-password", form.getValue("FORM_PANEL_PASSWORD"))
    }

    @Test fun loginCredentialFormAcceptsProtectedStoreOnlyExport() {
        // CURRENT-LOGIN-CREDENTIALS.env intentionally has no run marker. The
        // Android read-only exporter adds a transport-local marker before
        // concatenating the store, so a failed rotation cannot strand a
        // complete credential set behind an empty HANDOFF-SECRETS file.
        val payload = """
            ${ProtocolParsers.HANDOFF_BEGIN}
            HANDOFF_RUN_STARTED=android-read-only-export
            VPS_LOGIN_USER=root
            VPS_LOGIN_PASSWORD=store-vps
            PANEL_USERNAME=operator
            PANEL_PASSWORD=store-panel
            ${ProtocolParsers.HANDOFF_END}
        """.trimIndent()
        val form = ProtocolParsers.loginCredentialForm(ProtocolParsers.handoff(payload))
        assertEquals("root", form.getValue("FORM_VPS_ACCOUNT"))
        assertEquals("store-vps", form.getValue("FORM_VPS_PASSWORD"))
        assertEquals("operator", form.getValue("FORM_PANEL_ACCOUNT"))
        assertEquals("store-panel", form.getValue("FORM_PANEL_PASSWORD"))
    }

    @Test fun loginCredentialFormPreservesIntentionalSecretSpaces() {
        val payload = """
            HANDOFF_RUN_STARTED=spaces
            VPS_LOGIN_USER=  root  
            VPS_LOGIN_PASSWORD=  vps-secret-with-spaces  
            PANEL_USERNAME=operator
            PANEL_PASSWORD=  panel-secret-with-spaces  
        """.trimIndent()
        val form = ProtocolParsers.loginCredentialForm(payload)
        assertEquals("root", form.getValue("FORM_VPS_ACCOUNT"))
        assertEquals("  vps-secret-with-spaces  ", form.getValue("FORM_VPS_PASSWORD"))
        assertEquals("  panel-secret-with-spaces  ", form.getValue("FORM_PANEL_PASSWORD"))
    }

    @Test fun loginCredentialFormNormalizesPaddedMixedCaseFieldNames() {
        val payload = listOf(
            "HANDOFF_RUN_STARTED=case-padding",
            "  vPs_Login_User =  case-root  ",
            "fOrM_vPs_PaSsWoRd=case-vps-password",
            "xUi_UsErNaMe = case-panel",
            "FoRm_PaNeL_PaSsWoRd=case-panel-password",
        ).joinToString("\n")
        val form = ProtocolParsers.loginCredentialForm(payload)
        assertEquals("case-root", form.getValue("FORM_VPS_ACCOUNT"))
        assertEquals("case-vps-password", form.getValue("FORM_VPS_PASSWORD"))
        assertEquals("case-panel", form.getValue("FORM_PANEL_ACCOUNT"))
        assertEquals("case-panel-password", form.getValue("FORM_PANEL_PASSWORD"))
    }

    @Test fun cdnXhttpLinkRequiresTheExactTlsProfile() {
        val link = "vless://8f6290c1-91f0-4509-a181-7cfe275ab7dc@www.example.com:8443?type=xhttp&encryption=none&path=%2F614d2bd1cf22d6072ec3b0f93c8d6c81%2F&host=www.example.com&mode=packet-up&security=tls&sni=www.example.com&fp=chrome#PNA-CDN-XHTTP-STAGE"
        val parsed = ProtocolParsers.cdnXHttpLink(link)
        assertEquals("www.example.com", parsed.domain)
        assertEquals(8443, parsed.port)
        assertEquals("/614d2bd1cf22d6072ec3b0f93c8d6c81/", parsed.path)
        val badSecurity = link.replace("security=tls", "security=none")
        assertThrows(IllegalArgumentException::class.java) { ProtocolParsers.cdnXHttpLink(badSecurity) }
        val generatedLabel = link.replace("#PNA-CDN-XHTTP-STAGE", "#TNA-CDN-XHTTP-ORANGE")
        assertEquals("TNA-CDN-XHTTP-ORANGE", ProtocolParsers.cdnXHttpLink(generatedLabel).label)
    }

    @Test fun canonicalizeCdnXhttpLinkMigratesLegacyFragmentAndPreservesOptionalQuery() {
        val legacy = "vless://8f6290c1-91f0-4509-a181-7cfe275ab7dc@www.example.com:8443?type=xhttp&encryption=none&path=%2F614d2bd1cf22d6072ec3b0f93c8d6c81%2F&host=www.example.com&mode=packet-up&security=tls&sni=www.example.com&fp=chrome&x_padding_bytes=100-1000&extra=%7B%22mode%22%3A%22packet-up%22%7D#TNA-CDN-XHTTP-ORANGE"
        val canonical = ProtocolParsers.canonicalizeCdnXHttpLink(legacy)
        assertEquals(legacy.substringBefore('#'), canonical.substringBefore('#'))
        assertTrue(canonical.endsWith("#PNA-CDN-XHTTP-ORANGE"))
        assertTrue(canonical.contains("x_padding_bytes=100-1000"))
        assertTrue(canonical.contains("extra=%7B%22mode%22%3A%22packet-up%22%7D"))
    }

    @Test fun completeHandoffCanonicalizesLegacyCdnAliasesAndDeduplicates() {
        val legacyLink = "vless://8f6290c1-91f0-4509-a181-7cfe275ab7dc@www.example.com:8443?type=xhttp&encryption=none&path=%2F614d2bd1cf22d6072ec3b0f93c8d6c81%2F&host=www.example.com&mode=packet-up&security=tls&sni=www.example.com&fp=chrome&x_padding_bytes=100-1000&extra=%7B%22mode%22%3A%22packet-up%22%7D#TNA-CDN-XHTTP-ORANGE"
        val legacy = """
            HANDOFF_RUN_STARTED=legacy-cdn
            CDN_XHTTP_LINK=$legacyLink
            XHTTP_LINK=$legacyLink
        """.trimIndent()
        val completed = ProtocolParsers.completeHandoff(
            legacy,
            mapOf(
                "CDN_XHTTP_LINK" to legacyLink,
                "XHTTP_LINK" to legacyLink,
            ),
        )
        assertFalse(completed.contains("#TNA-CDN-"))
        assertTrue(completed.contains("#PNA-CDN-XHTTP-ORANGE"))
        assertTrue(completed.contains("x_padding_bytes=100-1000"))
        assertTrue(completed.contains("extra=%7B%22mode%22%3A%22packet-up%22%7D"))
        assertFalse(completed.contains("\nXHTTP_LINK="))
        assertEquals(1, completed.windowed("CDN_XHTTP_LINK=".length, 1).count { it == "CDN_XHTTP_LINK=" })
    }

    @Test fun completeHandoffRegeneratesEveryKnownProtocolKeyFromArchiveAndCurrent() {
        val oldReality = "vless://11111111-1111-4111-8111-111111111111@old.example.com:443?security=reality#old"
        val currentReality = "vless://22222222-2222-4222-8222-222222222222@new.example.com:443?security=reality#current"
        val oldSubscription = "https://old.example.com/sub/old-client"
        val currentSubscription = "https://new.example.com/sub/current-client"
        val oldSs2022 = "ss://b2xkLXNlY3JldA@old.example.com:32443#old-ss2022"
        val currentSs2022 = "ss://bmV3LXNlY3JldA@new.example.com:32443#current-ss2022"
        // The exporter orders archived files before the current file.  Every
        // known protocol key is deliberately repeated; only the current value
        // must survive in the protected v1 handoff appendix.
        val legacy = """
            HANDOFF_RUN_STARTED=archive
            REALITY_CLIENT_1_LINK=$oldReality
            REALITY_CLIENT_1_LINK=$currentReality
            SS2022_LINK=$oldSs2022
            SS2022_LINK=$currentSs2022
            SUBSCRIPTION_URL=$oldSubscription
            SUBSCRIPTION_URL=$currentSubscription
            UNKNOWN_KEEP=forward-compatible
        """.trimIndent()
        val completed = ProtocolParsers.completeHandoff(
            legacy,
            mapOf(
                "FORM_VPS_ACCOUNT" to "root",
                "FORM_VPS_PASSWORD" to "vps-secret",
                "FORM_PANEL_ACCOUNT" to "operator",
                "FORM_PANEL_PASSWORD" to "panel-secret",
            ),
        )
        assertTrue(completed.contains("REALITY_CLIENT_1_LINK=$currentReality"))
        assertTrue(completed.contains("SS2022_LINK=$currentSs2022"))
        assertTrue(completed.contains("SUBSCRIPTION_URL=$currentSubscription"))
        assertFalse(completed.contains("REALITY_CLIENT_1_LINK=$oldReality"))
        assertFalse(completed.contains("SS2022_LINK=$oldSs2022"))
        assertFalse(completed.contains("SUBSCRIPTION_URL=$oldSubscription"))
        assertTrue(completed.contains("UNKNOWN_KEEP=forward-compatible"))
        assertEquals(1, completed.windowed("REALITY_CLIENT_1_LINK=".length, 1).count { it == "REALITY_CLIENT_1_LINK=" })
        assertEquals(1, completed.windowed("SS2022_LINK=".length, 1).count { it == "SS2022_LINK=" })
        assertEquals(1, completed.windowed("SUBSCRIPTION_URL=".length, 1).count { it == "SUBSCRIPTION_URL=" })
    }

    @Test fun completeHandoffRecoversTypedAliasesAfterMalformedCurrentRows() {
        val oldUuid = "11111111-1111-4111-8111-111111111111"
        val oldPath = "/0123456789abcdef0123456789abcdef/"
        val oldLink = "vless://$oldUuid@old.example.com:8443?type=xhttp&encryption=none&path=%2F0123456789abcdef0123456789abcdef%2F&host=old.example.com&mode=packet-up&security=tls&sni=old.example.com&fp=chrome#TNA-CDN-XHTTP-ORANGE"
        val legacy = """
            HANDOFF_RUN_STARTED=archive
            XHTTP_UUID=$oldUuid
            XHTTP_DOMAIN=old.example.com
            XHTTP_PATH=$oldPath
            XHTTP_PUBLIC_PORT=8443
            XHTTP_LINK=$oldLink
            SS2022_HOST=192.0.2.10
            SS2022_PORT=32443
            PUBLIC_IP_AT_HANDOFF=192.0.2.10
            XHTTP_DOMAIN=UNKNOWN_NOT_RETAINED
            XHTTP_PATH=/malformed path
            XHTTP_PUBLIC_PORT=70000
            XHTTP_LINK=not-a-link
            SS2022_HOST=bad host
            SS2022_PORT=70000
            PUBLIC_IP_AT_HANDOFF=not-an-ip-or-host value
            UNKNOWN_KEEP=preserve-me
        """.trimIndent()
        val currentUuid = "22222222-2222-4222-8222-222222222222"
        val currentLink = oldLink
            .replace(oldUuid, currentUuid)
            .replace("old.example.com", "new.example.com")
            .replace("#TNA-CDN-XHTTP-ORANGE", "#PNA-CDN-XHTTP-ORANGE")
        val completed = ProtocolParsers.completeHandoff(
            legacy,
            mapOf(
                // Explicit values represent the current run and must beat the
                // archived aliases, even when the current raw rows were bad.
                "XHTTP_UUID" to currentUuid,
                "XHTTP_DOMAIN" to "new.example.com",
                "XHTTP_PATH" to "/fedcba9876543210fedcba9876543210/",
                "XHTTP_PUBLIC_PORT" to "8443",
                "XHTTP_LINK" to currentLink,
                "SS2022_HOST" to "new.example.com",
                "SS2022_PORT" to "32443",
                "PUBLIC_IP_AT_HANDOFF" to "198.51.100.2",
            ),
        )
        assertTrue(completed.contains("CDN_XHTTP_UUID=$currentUuid"))
        assertTrue(completed.contains("CDN_XHTTP_DOMAIN=new.example.com"))
        assertTrue(completed.contains("CDN_XHTTP_PATH=/fedcba9876543210fedcba9876543210/"))
        assertTrue(completed.contains("CDN_XHTTP_LINK=$currentLink"))
        assertTrue(completed.contains("SS2022_HOST=new.example.com"))
        assertTrue(completed.contains("PUBLIC_IP_AT_HANDOFF=198.51.100.2"))
        assertFalse(completed.contains("\nXHTTP_DOMAIN="))
        assertFalse(completed.contains("\nXHTTP_PATH="))
        assertFalse(completed.contains("\nXHTTP_LINK="))
        assertFalse(completed.contains("UNKNOWN_NOT_RETAINED"))
        assertFalse(completed.contains("70000"))
        assertFalse(completed.contains("bad host"))
        assertTrue(completed.contains("UNKNOWN_KEEP=preserve-me"))
        assertEquals(1, completed.windowed("CDN_XHTTP_DOMAIN=".length, 1).count { it == "CDN_XHTTP_DOMAIN=" })
        assertEquals(1, completed.windowed("SS2022_PORT=".length, 1).count { it == "SS2022_PORT=" })
    }

    @Test fun cdnStageEvidenceRequiresAndRecognizesEveryPhase() {
        val evidence = ProtocolParsers.cdnStageEvidence(
            """
            TNA_CDN_CERTIFICATE_ALREADY_VALID=1
            TNA_XHTTP_RETARGETED=1
            CDN_NGINX_STATUS=STAGED
            CDN_ORIGIN_READY=1
            CDN_EDGE_VALIDATED=1
            CDN_CLIENT_CONFIRMED=1
            TNA_TOPOLOGY_STAGED=1
            TNA_TOPOLOGY_RECONCILED=1
            TOPOLOGY_MODE=dual
            """.trimIndent(),
        )
        assertTrue(evidence.completeForEdge)
        assertTrue(evidence.clientConfirmed)
        assertTrue(evidence.topologyStaged)
        assertTrue(evidence.topologyReconciled)
        assertEquals("dual", evidence.mode)
        assertFalse(ProtocolParsers.cdnStageEvidence("TNA_TOPOLOGY_STAGED=1").completeForEdge)
    }

    @Test fun validatedProtocolFieldsRejectMalformedRouteValuesAndUnknownPrefixes() {
        val uuid = "11111111-1111-4111-8111-111111111111"
        val cdn = "vless://$uuid@edge.example.com:8443?type=xhttp&encryption=none&path=%2F614d2bd1cf22d6072ec3b0f93c8d6c81%2F&host=edge.example.com&mode=packet-up&security=tls&sni=edge.example.com&fp=chrome#PNA-CDN-XHTTP-STAGE"
        val legacyCdn = cdn.replace("#PNA-CDN-XHTTP-STAGE", "#TNA-CDN-XHTTP-STAGE")
        val fields = ProtocolParsers.validatedHandoffProtocolFields(
            mapOf(
                "CDN_XHTTP_LINK" to legacyCdn,
                "CDN_XHTTP_SUBSCRIPTION_URL" to "https://edge.example.com/sub/client-one",
                "REALITY_CLIENT_1_LINK" to "vless://$uuid@edge.example.com:443?security=reality",
                "REALITY_CLIENT_2_LINK" to "not-a-link",
                "SS2022_LINK" to "ss://YWVzLTIwMjItYmxha2UzLWF1dGgtc2hhMjU2QGtleQ==@edge.example.com:32443#ProxyNodeAssistant-SS2022-TCP",
                "SS2022_PASSWORD" to "ss-secret",
                "SS2022_PORT" to "32443",
                "REALITY_UNKNOWN_BLOB" to "must-not-be-copied",
                "CDN_XHTTP_LINK_EXTRA" to "must-not-be-copied",
            ),
        )
        assertEquals(cdn, fields["CDN_XHTTP_LINK"])
        assertEquals("https://edge.example.com/sub/client-one", fields["CDN_XHTTP_SUBSCRIPTION_URL"])
        assertTrue(fields.containsKey("REALITY_CLIENT_1_LINK"))
        assertFalse(fields.containsKey("REALITY_CLIENT_2_LINK"))
        assertTrue(fields.containsKey("SS2022_LINK"))
        assertEquals("ss-secret", fields["SS2022_PASSWORD"])
        assertFalse(fields.containsKey("REALITY_UNKNOWN_BLOB"))
        assertFalse(fields.containsKey("CDN_XHTTP_LINK_EXTRA"))
    }

    @Test fun stableIdentityAndPublicIpValidationAreFailClosed() {
        val value = """
            ${ProtocolParsers.NODE_IDENTITY_BEGIN}
            SERVER_ID=pna-srv-0123456789abcdef0123456789abcdef
            NODE_ID=pna-node-0123456789abcdef0123456789abcdef
            MACHINE_ID_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
            MACHINE_ID_MATCH=1
            SSH_HOST_KEY_SHA256=SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789
            SSH_HOST_KEY_MATCH=1
            FIRST_KNOWN_PUBLIC_IP=45.78.69.179
            CURRENT_PUBLIC_IP=45.78.69.179
            ${ProtocolParsers.NODE_IDENTITY_END}
        """.trimIndent()
        val identity = ProtocolParsers.stableNodeIdentity(value, "root@45.78.69.179:22")
        assertEquals("pna-srv-0123456789abcdef0123456789abcdef", identity.serverId)
        assertTrue(ProtocolParsers.validCanonicalPublicIpv4("45.78.69.179"))
        assertFalse(ProtocolParsers.validCanonicalPublicIpv4("192.168.1.1"))
        assertFalse(ProtocolParsers.validCanonicalPublicIpv4("203.0.113.10"))
        assertFalse(ProtocolParsers.validCanonicalPublicIpv4("01.2.3.4"))
    }
}
