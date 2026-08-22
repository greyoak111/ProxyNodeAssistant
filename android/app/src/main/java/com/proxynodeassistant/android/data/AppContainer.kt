package com.proxynodeassistant.android.data

import android.content.Context
import com.proxynodeassistant.android.core.PromptBroker
import com.proxynodeassistant.android.remote.SshEngine
import com.proxynodeassistant.android.remote.WorkflowRunner

class AppContainer(context: Context) {
    private val applicationContext = context.applicationContext
    val vault = EncryptedVault(applicationContext)
    val targets = TargetRepository(applicationContext)
    val hostKeys = HostKeyRepository(vault)
    val managedKeys = ManagedKeyRepository(applicationContext, vault)
    val providerCredentials = ProviderCredentialRepository(vault)
    val providerUsage = ProviderUsageRepository(applicationContext)
    val providerTraffic = ProviderTrafficClient()
    val prompts = PromptBroker()
    val ssh = SshEngine(hostKeys, managedKeys, prompts)
    val workflows = WorkflowRunner(applicationContext, ssh, managedKeys, targets, prompts)
}
