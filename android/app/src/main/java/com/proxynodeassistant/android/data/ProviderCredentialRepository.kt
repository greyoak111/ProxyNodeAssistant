package com.proxynodeassistant.android.data

class ProviderCredentialRepository(private val vault: EncryptedVault) {
    private fun name(provider: String, profileId: String) = "provider:${provider.lowercase()}:$profileId"
    fun put(provider: String, profileId: String, secret: String) = vault.put(name(provider, profileId), secret)
    fun get(provider: String, profileId: String): String? = vault.get(name(provider, profileId))
    fun delete(provider: String, profileId: String) = vault.remove(name(provider, profileId))
}
