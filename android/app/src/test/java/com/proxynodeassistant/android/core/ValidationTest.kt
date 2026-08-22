package com.proxynodeassistant.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ValidationTest {
    @Test fun hostsRejectShellAndCredentialSyntax() {
        assertTrue(Validation.validHost("node.example.com"))
        assertTrue(Validation.validHost("203.0.113.10"))
        assertFalse(Validation.validHost("root@example.com"))
        assertFalse(Validation.validHost("host;reboot"))
        assertFalse(Validation.validHost("../etc/passwd"))
    }

    @Test fun domainAndEmailMustBeHumanInputs() {
        assertTrue(Validation.validDomain("cover.example.com"))
        assertFalse(Validation.validDomain("localhost"))
        assertTrue(Validation.validEmail("ops@example.com"))
        assertFalse(Validation.validEmail("not-an-email"))
    }

    @Test fun templateSelectionIsBounded() {
        assertEquals("random", Validation.normalizeTemplate("R"))
        assertEquals("auto", Validation.normalizeTemplate("stable"))
        assertEquals("15", Validation.normalizeTemplate("15"))
        assertNull(Validation.normalizeTemplate("16"))
    }
}
