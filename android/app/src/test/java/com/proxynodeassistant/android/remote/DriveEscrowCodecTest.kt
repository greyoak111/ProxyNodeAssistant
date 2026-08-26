package com.proxynodeassistant.android.remote

import com.proxynodeassistant.android.data.DeviceIdentityRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DriveEscrowCodecTest {
    @Test
    fun encryptedCredentialRoundTripsOnlyThroughControllerEnvelope() {
        val repository = DeviceIdentityRepository(mutableMapOf())
        val identity = repository.loadOrCreate()
        val password = "v095-test-credential-DoNotPersist"

        val encrypted = DriveEscrowCodec.encryptNew(
            nodeId = "tna-node-0123456789abcdef0123456789abcdef",
            accountId = "tna-account-0123456789abcdef0123456789abcdef",
            spaceId = "tna-space-fedcba9876543210fedcba9876543210",
            username = "ordinary-user",
            password = password,
            controllers = listOf(ControllerEncryptionKey(identity.deviceId, identity.encryptionPublic)),
            keys = repository,
        )
        val encoded = DriveEscrowCodec.encode(encrypted)

        assertNotEquals(password, encoded)
        assertEquals(password, DriveEscrowCodec.decrypt(DriveEscrowCodec.decode(encoded), identity, repository))
    }
}
