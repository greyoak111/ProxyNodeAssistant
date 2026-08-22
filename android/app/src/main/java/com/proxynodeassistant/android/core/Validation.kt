package com.proxynodeassistant.android.core

import java.net.IDN

object Validation {
    private val userPattern = Regex("^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$")
    private val emailPattern = Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")

    fun validHost(value: String): Boolean {
        val host = value.trim()
        if (host.isEmpty() || host.length > 253 || host.any { it.isWhitespace() || it in "/@\\" }) return false
        if (host.contains(':')) return host.matches(Regex("^[0-9a-fA-F:]+$"))
        return runCatching { IDN.toASCII(host) }.getOrNull()?.matches(Regex("^[A-Za-z0-9.-]+$")) == true
    }

    fun validUser(value: String) = userPattern.matches(value.trim())
    fun validPort(value: Int) = value in 1..65535

    fun validDomain(value: String): Boolean {
        val domain = runCatching { IDN.toASCII(value.trim()) }.getOrNull() ?: return false
        if (domain.length > 253) return false
        return Regex("(?i)^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$").matches(domain)
    }

    fun validEmail(value: String) = emailPattern.matches(value.trim())

    // Password managers and chat apps commonly append CR/LF when copying a
    // single-line secret. Preserve every other character, including spaces.
    fun singleLineSecret(value: String): String = value.replace("\r", "").replace("\n", "")

    fun normalizeTemplate(value: String): String? = when (val answer = value.trim().lowercase()) {
        "", "r", "random" -> "random"
        "a", "auto", "stable" -> "auto"
        else -> answer.toIntOrNull()?.takeIf { it in 1..15 }?.toString()
    }
}
