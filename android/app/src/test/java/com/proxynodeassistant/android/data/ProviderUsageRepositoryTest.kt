package com.proxynodeassistant.android.data

import com.proxynodeassistant.android.model.CachedKiwiUsage
import com.proxynodeassistant.android.model.KiwiUsage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ProviderUsageRepositoryTest {
    @Test
    fun nonSecretTrafficSnapshotRoundTrips() {
        val usage = KiwiUsage(
            veid = "123456",
            hostname = "node-label",
            location = "US",
            plan = "plan",
            usedBytes = 7_000_000_000,
            allowanceBytes = 1_000_000_000_000,
            multiplier = 1.0,
            resetEpochSeconds = 1_800_000_000,
            suspended = false,
            policyViolation = false,
        )
        val expected = CachedKiwiUsage(usage, 1_700_000_000_000)
        val decoded = ProviderUsageRepository.decode(ProviderUsageRepository.encode(expected))
        assertEquals(expected, decoded)
    }

    @Test
    fun invalidOrIncompleteCacheIsRejected() {
        assertNull(ProviderUsageRepository.decode("{}"))
        assertNull(ProviderUsageRepository.decode("not-json"))
    }
}
