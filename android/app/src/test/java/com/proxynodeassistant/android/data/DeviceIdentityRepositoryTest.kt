package com.proxynodeassistant.android.data

import android.content.Context
import org.junit.Assert.assertArrayEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DeviceIdentityRepositoryTest {
    @Test
    fun x25519PublicMatchesRfc7748Vector() {
        val context = RuntimeEnvironment.getApplication() as Context
        val repository = DeviceIdentityRepository(EncryptedVault(context))
        val scalar = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        val expected = hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        assertArrayEquals(expected, repository.x25519Public(scalar))
    }

    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
