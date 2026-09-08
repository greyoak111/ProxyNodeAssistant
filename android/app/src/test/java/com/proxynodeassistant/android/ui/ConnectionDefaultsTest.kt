package com.proxynodeassistant.android.ui

import com.proxynodeassistant.android.model.AuthMode
import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.ManagedKeyRecord
import com.proxynodeassistant.android.model.NodeTarget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConnectionDefaultsTest {
    private val target = NodeTarget("45.78.69.179", "root", 22)

    @Test
    fun latestTargetUsesManagedKeyOnlyWhenBoundPairMatches() {
        val bound = ManagedKeyRecord(target.id, "private", "public", KeyStatus.BOUND)
        assertEquals(AuthMode.MANAGED_KEY, defaultAuthModeForTarget(target, listOf(bound)))
        assertNull(defaultAuthModeForTarget(target, listOf(bound.copy(status = KeyStatus.BACKUP))))
        assertNull(defaultAuthModeForTarget(target, emptyList()))
    }

    @Test
    fun missingTargetNeverSelectsAnAuthenticationMode() {
        val bound = ManagedKeyRecord(target.id, "private", "public", KeyStatus.BOUND)
        assertNull(defaultAuthModeForTarget(null, listOf(bound)))
    }
}
