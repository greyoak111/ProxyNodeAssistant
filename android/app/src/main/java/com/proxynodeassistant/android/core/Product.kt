package com.proxynodeassistant.android.core

object Product {
    const val NAME = "TextNodeAssistant"
    const val ABBREVIATION = "TNA"
    const val VERSION = "0.9.5"
    const val BUILD_ID = "20260827-v095-tna-cdn-acme-origin-8443-r29"
    const val BUILD_REVISION = 28

    const val REMOTE_ROOT = "/opt/text-node-assistant-current"
    const val INSTALL_ROOT = "/opt/text-node-assistant-v0.9.5"
    const val TOOLKIT_ASSET = "text-node-assistant-toolkit-v0.9.5.tgz"
    const val TOOLKIT_ARCHIVE = "text-node-assistant-toolkit-v0.9.5.tar.gz"

    const val STATE_ROOT = "/etc/text-node-assistant"
    const val SECRET_ROOT = "/root/.config/text-node-assistant"

    // Read-only migration compatibility. New writes always use the TNA paths above.
    const val LEGACY_REMOTE_ROOT = "/opt/proxy-runbook-current"
    const val LEGACY_STATE_ROOT = "/etc/proxy-runbook"
    const val LEGACY_SECRET_ROOT = "/root/.config/proxy-runbook"
}
