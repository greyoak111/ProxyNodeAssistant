package com.proxynodeassistant.android.remote

import android.util.Base64
import com.proxynodeassistant.android.core.PromptBroker
import com.proxynodeassistant.android.data.HostKeyRepository
import com.proxynodeassistant.android.data.ManagedKeyRepository
import com.proxynodeassistant.android.model.AuthMode
import com.proxynodeassistant.android.model.HostKeyRecord
import com.proxynodeassistant.android.model.Language
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
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

data class SessionCredential(val mode: AuthMode, val password: String? = null)
data class ReboundSshSession(
    val handle: SshHandle,
    val presentedHostKey: HostKeyRecord,
    val usedPasswordFallback: Boolean,
)

class SshEngine(
    private val hostKeys: HostKeyRepository,
    private val managedKeys: ManagedKeyRepository,
    private val prompts: PromptBroker,
) {
    /**
     * Connect to a new endpoint while accepting only the host key pinned for
     * the old endpoint and authenticating with the already-bound key.  This is
     * intentionally separate from normal connect(): a changed public IP must
     * never be treated as a first-time host-key approval.
     */
    suspend fun connectRebound(
        oldTarget: NodeTarget,
        newTarget: NodeTarget,
        password: String?,
        language: Language = Language.ZH,
    ): ReboundSshSession = withContext(Dispatchers.IO) {
        require(oldTarget.id != newTarget.id) { "REBOUND_TARGET_UNCHANGED" }
        val pinned = hostKeys.get(oldTarget.id) ?: error("LOCAL_HOST_KEY_RECORD_NOT_FOUND")
        val key = managedKeys.get(oldTarget.id) ?: error("LOCAL_KEY_RECORD_NOT_FOUND")
        var presented: HostKeyRecord? = null
        var hostKeyWasPresented = false
        val connection = Connection(newTarget.host, newTarget.port)
        val verifier = ServerHostKeyVerifier { _, _, algorithm, serverHostKey ->
            hostKeyWasPresented = true
            val encoded = Base64.encodeToString(serverHostKey, Base64.NO_WRAP)
            val fingerprint = KeyFingerprint.createSHA256Fingerprint(serverHostKey)
            val candidate = HostKeyRecord(newTarget.id, algorithm, encoded, fingerprint)
            if (pinned.algorithm == algorithm && pinned.keyBase64 == encoded && pinned.fingerprint == fingerprint) {
                presented = candidate
                true
            } else {
                false
            }
        }
        try {
            try {
                connection.connect(verifier, 12_000, 25_000)
            } catch (error: Throwable) {
                throw IllegalStateException(if (hostKeyWasPresented) "HOST_KEY_MISMATCH" else "SSH_HOST_KEY_UNAVAILABLE", error)
            }
            var usedPassword = false
            var authenticated = connection.authenticateWithPublicKey(newTarget.user, key.privateKeyOpenSsh.toCharArray(), null)
            if (!authenticated && password != null) {
                usedPassword = true
                authenticated = authenticatePassword(connection, newTarget.user, password)
            }
            check(authenticated) { if (password == null) "PUBLICKEY_REJECTED" else "PUBLICKEY_REJECTED_AND_PASSWORD_FAILED" }
            ReboundSshSession(
                SshHandle(connection, newTarget, password, prompts, language),
                requireNotNull(presented),
                usedPassword,
            )
        } catch (error: Throwable) {
            connection.close()
            throw error
        }
    }

    suspend fun connect(target: NodeTarget, credential: SessionCredential, language: Language = Language.ZH): SshHandle = withContext(Dispatchers.IO) {
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
                    if (changed) appendLine(if (language == Language.ZH) "危险：已固定的 SSH 主机公钥发生变化" else "DANGER: the pinned SSH host key changed")
                    else appendLine(if (language == Language.ZH) "首次连接此节点" else "First connection")
                    appendLine(if (language == Language.ZH) "目标：${target.id}" else "Target: ${target.id}")
                    appendLine(if (language == Language.ZH) "算法：$algorithm" else "Algorithm: $algorithm")
                    appendLine(if (language == Language.ZH) "当前指纹：$fingerprint" else "Fingerprint: $fingerprint")
                    pinned?.let { appendLine(if (language == Language.ZH) "原固定指纹：${it.fingerprint}" else "Previously pinned: ${it.fingerprint}") }
                    append(if (changed) {
                        if (language == Language.ZH) "确认服务商控制台指纹后，输入大写 REPLACE 才能替换。" else "Type REPLACE to trust this replacement."
                    } else {
                        if (language == Language.ZH) "与服务商控制台指纹核对后，输入大写 TRUST。" else "Type TRUST after comparing the provider fingerprint."
                    })
                }
                val expected = if (changed) "REPLACE" else "TRUST"
                val answer = runBlocking {
                    prompts.ask(
                        title = if (changed) {
                            if (language == Language.ZH) "SSH 主机公钥已变化" else "Host Key changed"
                        } else {
                            if (language == Language.ZH) "核对 SSH 主机公钥" else "Verify SSH Host Key"
                        },
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
            when (credential.mode) {
                AuthMode.TEMPORARY_PASSWORD -> {
                    val authenticated = authenticatePassword(connection, target.user, requireNotNull(credential.password))
                    check(authenticated) {
                        if (language == Language.ZH) "SSH 服务器拒绝了 ${target.id} 的密码。密码区分大小写；粘贴时请确认没有多余字符，也可改用已绑定密钥。"
                        else "The SSH server rejected the password for ${target.id}. Passwords are case-sensitive; check pasted characters or use a bound key."
                    }
                }
                AuthMode.MANAGED_KEY -> {
                    val key = managedKeys.get(target.id) ?: error(if (language == Language.ZH) "${target.id} 没有已绑定的 SSH 密钥" else "No bound SSH key for ${target.id}")
                    val authenticated = connection.authenticateWithPublicKey(target.user, key.privateKeyOpenSsh.toCharArray(), null)
                    check(authenticated) {
                        if (language == Language.ZH) "SSH 服务器拒绝了 ${target.id} 的已绑定密钥；请检查远端 authorized_keys，或改用临时密码后重新绑定。"
                        else "The SSH server rejected the bound key for ${target.id}; check authorized_keys or rebind using a temporary password."
                    }
                }
            }
            candidate?.let(hostKeys::put)
            SshHandle(connection, target, credential.password, prompts, language)
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
    private val language: Language,
) : Closeable {
    private val forwards = Collections.synchronizedList(mutableListOf<LocalPortForwarder>())
    private var cachedSudoPassword: String? = loginPassword
    private val keepAlive = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "pna-ssh-keepalive").apply { isDaemon = true }
    }.apply {
        scheduleWithFixedDelay({ runCatching { connection.sendIgnorePacket() } }, 15, 15, TimeUnit.SECONDS)
    }

    suspend fun exec(
        command: String,
        root: Boolean = true,
        interactive: Boolean = false,
        stdinBytes: ByteArray? = null,
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
                    if (language == Language.ZH) "sudo 密码" else "sudo password",
                    if (language == Language.ZH) "请输入 ${target.user}@${target.host} 的 sudo 密码。它只保留在本次实时会话中。" else "Enter the sudo password for ${target.user}@${target.host}. It remains only in this live session.",
                    PromptKind.SECRET,
                ).also { cachedSudoPassword = it }
                synchronized(stdinLock) {
                    stdin.write((password + "\n").toByteArray())
                    stdin.flush()
                }
            }
            if (stdinBytes != null) {
                synchronized(stdinLock) {
                    stdin.write(stdinBytes)
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
                    val answer = prompts.ask(if (language == Language.ZH) "远端操作输入" else "Remote confirmation", prompt.second, prompt.first)
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
        val variants = listOf(
            "PNA_GUI_PROMPT_B64=" to PromptKind.TEXT,
            "PNA_GUI_SECRET_B64=" to PromptKind.SECRET,
            // v0.9.x toolkit prompts are accepted during an in-place upgrade.
            "TNA_GUI_PROMPT_B64=" to PromptKind.TEXT,
            "TNA_GUI_SECRET_B64=" to PromptKind.SECRET,
        )
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
        keepAlive.shutdownNow()
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
