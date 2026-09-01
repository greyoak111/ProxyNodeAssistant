package com.proxynodeassistant.android.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidNetworkProbesTest {
    @Test
    fun normalizeAcceptsOnlyExactGlobalIpv4() {
        assertEquals("112.22.55.164", AndroidNetworkProbes.normalizePublicIpv4(" 112.22.55.164\n"))
        assertEquals("8.8.8.8", AndroidNetworkProbes.normalizePublicIpv4("8.8.8.8 extra"))
        listOf("10.0.0.1", "192.168.1.4", "172.16.0.1", "127.0.0.1", "224.0.0.1", "8.8.8.8/32", "999.1.1.1", "01.2.3.4").forEach {
            assertNull("must reject $it", AndroidNetworkProbes.normalizePublicIpv4(it))
        }
    }

    @Test
    fun endpointSetIsDirectAndHasMultipleIndependentSources() {
        assertTrue(AndroidNetworkProbes.publicIpv4Endpoints.size >= 3)
        assertTrue(AndroidNetworkProbes.publicIpv4Endpoints.all { it.startsWith("https://") })
        assertTrue(AndroidNetworkProbes.publicIpv4Endpoints.distinct().size == AndroidNetworkProbes.publicIpv4Endpoints.size)
    }
}
