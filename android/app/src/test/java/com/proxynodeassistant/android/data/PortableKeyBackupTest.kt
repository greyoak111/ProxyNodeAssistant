package com.proxynodeassistant.android.data

import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.ManagedKeyRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PortableKeyBackupTest {
    private val record = ManagedKeyRecord(
        targetId = "root@node.example:22",
        privateKeyOpenSsh = "-----BEGIN OPENSSH PRIVATE KEY-----\nTEST-DATA\n-----END OPENSSH PRIVATE KEY-----",
        publicKeyOpenSsh = "ssh-ed25519 AAAATEST proxy-node-assistant-android",
        status = KeyStatus.BACKUP,
        createdEpochMs = 123456789,
    )

    @Test fun encryptedRoundTripPreservesRecord() {
        val encrypted = PortableKeyBackup.export(listOf(record), "correct horse battery".toCharArray())
        assertTrue(encrypted.size > 64)
        assertTrue(encrypted.toString(Charsets.UTF_8).contains("OPENSSH").not())
        val restored = PortableKeyBackup.import(encrypted, "correct horse battery".toCharArray()).single()
        assertEquals(record, restored)
    }

    @Test fun wrongPassphraseFailsClosed() {
        val encrypted = PortableKeyBackup.export(listOf(record), "correct horse battery".toCharArray())
        assertThrows(IllegalArgumentException::class.java) { PortableKeyBackup.import(encrypted, "incorrect horse words".toCharArray()) }
    }
}
