package com.proxynodeassistant.android.remote

import android.util.Base64
import com.proxynodeassistant.android.core.PromptBroker
import com.proxynodeassistant.android.data.HostKeyRepository
import com.proxynodeassistant.android.data.ManagedKeyRepository
import com.proxynodeassistant.android.model.AuthMode
import com.proxynodeassistant.android.model.HostKeyRecord
import com.proxynodeassistant.android.model.NodeTarget
import com.proxynodeassistant.android.model.PromptKind
import com.proxynodeassistant.android.model.RemoteResult
import com.trilead.ssh2.ChannelCondition
import com.trilead.ssh2.Connection
import com.trilead.ssh2.InteractiveCallback
import com.trilead.ssh2.LocalPortForwarder
import com.trilead.ssh2.SCPClient
import com.trilead.ssh2.ServerHostKeyVerifier
import com.trilead.ssh2.crypto.fingerprint.KeyFingerprint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.Collections
import kotlin.coroutines.coroutineContext

data class SessionCredential(val mode: AuthMode, val password: String? = null)

class SshEngine(
    private val hostKeys: HostKeyRepository,
    private val managedKeys: ManagedKeyRepository,
    private val prompts: PromptBroker,
) {
    suspend fun connect(target: NodeTarget, credential: SessionCredential): SshHandle = withContext(Dispatchers.IO) {
        var candidate: HostKeyRecord? = null
        val connection = Connection(target.host, target.port)
        val verifier = ServerHostKeyVerifier { _, _, algorithm, serverHostKey ->
            val encoded = Base64.encodeToString(serverHostKey, Base64.NO_WRAP)
            val fingerprint = KeyFingerprint.createSHA256Fingerprint(serverHostKey)
            val presented = HostKeyRecord(target.id, algorithm, encoded, fingerprint)
            val pinned = hostKeys.get(target.id)
            if (pinned != null && pinned.algorithm == algorithm && pinned.keyBase64 == encoded) {
                true
            } else {
                val changed = pinned != null
                val message = buildString {
                    if (changed) appendLine("DANGER: the pinned host key changed / 危险：已固定的 Host Key 发生变化")
                    else appendLine("First connection / 首次连接")
                    appendLine("Target: ${target.id}")
                    appendLine("Algorithm: $algorithm")
                    appendLine("Fingerprint: $fingerprint")
                    pinned?.let { appendLine("Previously pinned: ${it.fingerprint}") }
                    append(if (changed) "Type REPLACE to trust this replacement." else "Type TRUST after comparing the provider fingerprint.")
                }
                val expected = if (changed) "REPLACE" else "TRUST"
                val answer = runBlocking {
                    prompts.ask(
                        title = if (changed) "Host Key changed" else "Verify SSH Host Key",
                        message = message,
                        kind = PromptKind.HOST_KEY,
                        placeholder = expected,
                        danger = changed,
                    )
                }
                if (answer.trim() == expected) {
                    candidate = presented
                    true
                } else {
                    false
                }
            }
        }

        try {
            connection.connect(verifier, 12_000, 25_000)
            val authenticated = when (credential.mode) {
                AuthMode.TEMPORARY_PASSWORD -> authenticatePassword(connection, target.user, requireNotNull(credential.password))
                AuthMode.MANAGED_KEY -> {
                    val key = managedKeys.get(target.id) ?: error("No bound SSH key for ${target.id}")
                    connection.authenticateWithPublicKey(target.user, key.privateKeyOpenSsh.toCharArray(), null)
                }
            }
            check(authenticated) { "SSH authentication failed for ${target.id}" }
            candidate?.let(hostKeys::put)
            SshHandle(connection, target, credential.password, prompts)
        } catch (error: Throwable) {
            connection.close()
            throw error
        }
    }

    private fun authenticatePassword(connection: Connection, user: String, password: String): Boolean {
        if (connection.authenticateWithPassword(user, password)) return true
        val methods = connection.getRemainingAuthMethods(user) ?: emptyArray()
        if (!methods.contains("keyboard-interactive")) return false
        return connection.authenticateWithKeyboardInteractive(user, InteractiveCallback { _, _, _, prompt, echo ->
            Array(prompt.size) { index -> if (echo[index]) "" else password }
        })
    }
}

class SshHandle internal constructor(
    private val connection: Connection,
    val target: NodeTarget,
    private val loginPassword: String?,
    private val prompts: PromptBroker,
) : Closeable {
    private val forwards = Collections.synchronizedList(mutableListOf<LocalPortForwarder>())
    private var cachedSudoPassword: String? = loginPassword

    suspend fun exec(
        command: String,
        root: Boolean = true,
        interactive: Boolean = false,
        log: suspend (String) -> Unit = {},
    ): RemoteResult = withContext(Dispatchers.IO) {
        val session = connection.openSession()
        val stdout = StringBuilder()
        val stderr = StringBuilder()
        val stdin = session.stdin
        val stdinLock = Any()
        try {
            if (interactive) session.requestPTY("xterm-256color", 120, 40, 0, 0, null)
            val wrapped = if (root) rootCommand(command) else "bash -lc ${shellQuote(command)}"
            session.execCommand(wrapped)
            if (root && target.user != "root") {
                val password = cachedSudoPassword ?: prompts.ask(
                    "sudo password",
                    "Enter the sudo password for ${target.user}@${target.host}. It remains only in this live session.",
                    PromptKind.SECRET,
                ).also { cachedSudoPassword = it }
                synchronized(stdinLock) {
                    stdin.write((password + "\n").toByteArray())
                    stdin.flush()
                }
            }
            coroutineScope {
                val outJob = async { pump(session.stdout, stdout, stdin, stdinLock, log) }
                val errJob = async { pump(session.stderr, stderr, stdin, stdinLock, log) }
                session.waitForCondition(ChannelCondition.EXIT_STATUS or ChannelCondition.EOF or ChannelCondition.CLOSED, 0)
                outJob.await()
                errJob.await()
            }
            RemoteResult(session.exitStatus ?: 255, stdout.toString(), stderr.toString())
        } finally {
            session.close()
        }
    }

    private suspend fun pump(
        input: java.io.InputStream,
        capture: StringBuilder,
        stdin: OutputStream,
        stdinLock: Any,
        log: suspend (String) -> Unit,
    ) {
        input.bufferedReader().use { reader ->
            while (true) {
                coroutineContext.ensureActive()
                val raw = reader.readLine() ?: break
                val line = stripAnsi(raw)
                val prompt = decodePrompt(line)
                if (prompt != null) {
                    val answer = prompts.ask("Remote confirmation", prompt.second, prompt.first)
                    synchronized(stdinLock) {
                        stdin.write((answer + "\n").toByteArray())
                        stdin.flush()
                    }
                } else {
                    capture.appendLine(line)
                    log(line)
                }
            }
        }
    }

    private fun decodePrompt(line: String): Pair<PromptKind, String>? {
        val variants = listOf("PNA_GUI_PROMPT_B64=" to PromptKind.TEXT, "PNA_GUI_SECRET_B64=" to PromptKind.SECRET)
        for ((prefix, kind) in variants) {
            val index = line.indexOf(prefix)
            if (index < 0) continue
            val payload = line.substring(index + prefix.length).trim()
            val decoded = runCatching { Base64.decode(payload, Base64.DEFAULT).toString(Charsets.UTF_8) }.getOrNull()
            if (!decoded.isNullOrBlank()) return kind to decoded
        }
        return null
    }

    fun upload(data: ByteArray, remoteFileName: String, remoteDirectory: String = "/tmp", mode: String = "0600") {
        SCPClient(connection).put(data, remoteFileName, remoteDirectory, mode)
    }

    fun download(remotePath: String, target: OutputStream) {
        SCPClient(connection).get(remotePath, target)
    }

    suspend fun downloadBytes(remotePath: String): ByteArray = withContext(Dispatchers.IO) {
        ByteArrayOutputStream().use { output ->
            download(remotePath, output)
            output.toByteArray()
        }
    }

    fun openLocalForward(remotePort: Int): PanelForward {
        val localPort = ServerSocket(0).use { it.localPort }
        val forwarder = connection.createLocalPortForwarder(InetSocketAddress("127.0.0.1", localPort), "127.0.0.1", remotePort)
        forwards += forwarder
        return PanelForward(localPort, forwarder) { forwards.remove(forwarder) }
    }

    private fun rootCommand(command: String): String = if (target.user == "root") {
        "bash -lc ${shellQuote(command)}"
    } else {
        "sudo -S -p '' -- bash -lc ${shellQuote(command)}"
    }

    override fun close() {
        synchronized(forwards) { forwards.toList().forEach { runCatching { it.close() } }; forwards.clear() }
        connection.close()
    }

    companion object {
        private val ansi = Regex("\\u001B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\u0007]*(?:\\u0007|\\u001B\\\\))")
        fun stripAnsi(value: String) = ansi.replace(value, "")
        fun shellQuote(value: String) = "'" + value.replace("'", "'\\''") + "'"
    }
}

class PanelForward(
    val localPort: Int,
    private val delegate: LocalPortForwarder,
    private val onClosed: () -> Unit,
) : Closeable {
    override fun close() {
        runCatching { delegate.close() }
        onClosed()
    }
}
