package com.proxynodeassistant.android.service

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.proxynodeassistant.android.remote.PanelForward
import com.proxynodeassistant.android.remote.SshHandle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

object TunnelRegistry {
    private val lock = Any()
    private var handle: SshHandle? = null
    private var forward: PanelForward? = null
    private val _url = MutableStateFlow<String?>(null)
    val url: StateFlow<String?> = _url.asStateFlow()

    fun install(context: Context, newHandle: SshHandle, newForward: PanelForward, panelUrl: String) {
        close(context)
        synchronized(lock) {
            handle = newHandle
            forward = newForward
            _url.value = panelUrl
        }
        ContextCompat.startForegroundService(context, Intent(context, PanelTunnelService::class.java).setAction(PanelTunnelService.ACTION_START))
    }

    fun close(context: Context? = null) {
        synchronized(lock) {
            runCatching { forward?.close() }
            runCatching { handle?.close() }
            forward = null
            handle = null
            _url.value = null
        }
        context?.stopService(Intent(context, PanelTunnelService::class.java))
    }
}
