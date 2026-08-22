package com.proxynodeassistant.android.remote

import android.content.Context
import android.util.Base64
import com.proxynodeassistant.android.core.PromptBroker
import com.proxynodeassistant.android.core.Validation
import com.proxynodeassistant.android.data.ManagedKeyRepository
import com.proxynodeassistant.android.data.TargetRepository
import com.proxynodeassistant.android.model.ActionSpec
import com.proxynodeassistant.android.model.AuthMode
import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.NodeTarget
import com.proxynodeassistant.android.model.PromptKind
import com.proxynodeassistant.android.model.RunStatus
import com.proxynodeassistant.android.model.ToolkitProbe
import com.proxynodeassistant.android.model.WorkflowUiState
import com.proxynodeassistant.android.service.TunnelRegistry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress

class WorkflowRunner(
    private val context: Context,
    private val ssh: SshEngine,
    private val managedKeys: ManagedKeyRepository,
    private val targets: TargetRepository,
    private val prompts: PromptBroker,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow(WorkflowUiState())
    val state: StateFlow<WorkflowUiState> = _state.asStateFlow()
    private var job: Job? = null
    @Volatile private var activeHandle: SshHandle? = null

    fun run(action: ActionSpec, target: NodeTarget, authMode: AuthMode, suppliedPassword: String? = null) {
        check(job?.isActive != true) { "A workflow is already running" }
        _state.value = WorkflowUiState(RunStatus.CONNECTING, action, target, startedAtEpochMs = System.currentTimeMillis())
        job = scope.launch {
            var handle: SshHandle? = null
            var tunnelTransferred = false
            try {
                targets.remember(target)
                log("PNA_ANDROID_WORKFLOW action=${action.code} target=${target.id}")
                handle = connect(target, authMode, suppliedPassword)
                activeHandle = handle
                _state.update { it.copy(status = RunStatus.RUNNING) }
                tunnelTransferred = execute(action.code.uppercase(), handle)
                _state.update { it.copy(status = RunStatus.SUCCEEDED) }
            } catch (_: CancellationException) {
                _state.update { it.copy(status = RunStatus.CANCELLED, error = "Operation cancelled safely") }
            } catch (error: Throwable) {
                log("FAIL_CLOSED: ${safeError(error)}")
                _state.update { it.copy(status = RunStatus.FAILED, error = safeError(error)) }
            } finally {
                prompts.cancel()
                activeHandle = null
                if (!tunnelTransferred) runCatching { handle?.close() }
            }
        }
    }

    fun submitPrompt(value: String) = prompts.submit(value)

    fun cancel() {
        prompts.cancel()
        activeHandle?.close()
        job?.cancel()
    }

    fun clear() {
        if (job?.isActive == true) return
        _state.value = WorkflowUiState()
    }

    private suspend fun connect(target: NodeTarget, mode: AuthMode, suppliedPassword: String?): SshHandle {
        if (mode == AuthMode.MANAGED_KEY && managedKeys.get(target.id) != null) {
            log("AUTH_MODE=MANAGED_KEY")
            return ssh.connect(target, SessionCredential(AuthMode.MANAGED_KEY))
        }
        val password = suppliedPassword?.takeIf { it.isNotBlank() } ?: prompts.ask(
            "SSH password",
            "Enter the current password for ${target.id}. It is sent only to the live SSH authentication exchange and is never logged or saved.",
            PromptKind.SECRET,
        )
        require(password.isNotEmpty()) { "SSH password cannot be empty" }
        log("AUTH_MODE=TEMPORARY_PASSWORD")
        val handle = ssh.connect(target, SessionCredential(AuthMode.TEMPORARY_PASSWORD, password))
        if (mode == AuthMode.MANAGED_KEY) {
            val answer = prompts.ask(
                "Bind this node?",
                "Password login succeeded. Bind a new node-specific Ed25519 key in Android Keystore? [y/N]",
                PromptKind.YES_NO,
                defaultValue = "n",
            )
            if (answer.equals("y", true) || answer.equals("yes", true)) bindNewKey(handle)
        }
        return handle
    }

    private suspend fun bindNewKey(handle: SshHandle) {
        val record = managedKeys.generate(handle.target.id)
        installPublicKey(handle, record.publicKeyOpenSsh)
        managedKeys.put(record)
        try {
            ssh.connect(handle.target, SessionCredential(AuthMode.MANAGED_KEY)).use { verifier ->
                val result = verifier.exec("printf SSH_KEY_OK", root = false)
                check(result.ok && result.stdout.trim() == "SSH_KEY_OK") { "new SSH key did not verify" }
            }
        } catch (error: Throwable) {
            managedKeys.delete(handle.target.id, KeyStatus.BOUND)
            removePublicKey(handle, record.publicKeyOpenSsh)
            throw IllegalStateException("New key verification failed; the key was rolled back", error)
        }
        _state.update { it.copy(secretHandoff = "SSH_PRIVATE_KEY\n${record.privateKeyOpenSsh}\nSSH_PUBLIC_KEY\n${record.publicKeyOpenSsh}") }
        log("SSH_KEY_BOUND_AND_VERIFIED")
    }

    private suspend fun execute(code: String, handle: SshHandle): Boolean = when (code) {
        "1" -> deploy(handle)
        "2" -> openPanel(handle)
        "3" -> { ensureToolkit(handle); checked(handle, "bash $REMOTE_ROOT/linux/16-auto-diagnose.sh --protocol-v1"); false }
        "4" -> { ensureToolkit(handle); confirmYes("Back up and run deterministic safe repair?", false); checked(handle, "bash $REMOTE_ROOT/linux/17-safe-auto-repair.sh", interactive = true); false }
        "5" -> { ensureToolkit(handle); rotateVpsPassword(handle); false }
        "6" -> { ensureToolkit(handle); rotatePanelCredentials(handle); false }
        "7" -> { showHandoff(handle); false }
        "8" -> { ensureToolkit(handle); optimizeCover(handle); false }
        "9" -> { ensureToolkit(handle); checked(handle, "bash $REMOTE_ROOT/linux/01-safe-backup.sh", interactive = true); false }
        "10" -> { ensureToolkit(handle); emergencyReport(handle); false }
        "11" -> { rotateManagedKey(handle); false }
        "13" -> { uninstallToolkit(handle); false }
        "15" -> { ensureToolkit(handle); pruneBackups(handle); false }
        "16" -> { ensureToolkit(handle); performanceProfile(handle); false }
        "17" -> { ensureToolkit(handle); trafficEstimate(handle); false }
        "18" -> { ensureToolkit(handle); dismantle(handle); false }
        "T" -> { ensureToolkit(handle); trafficEstimate(handle); log("Provider API profiles are managed from the local Provider screen."); false }
        else -> error("Action $code is local or unsupported in the remote runner")
    }

    private suspend fun deploy(handle: SshHandle): Boolean {
        val probe = probe(handle)
        val comparison = if (probe.installed) ProtocolParsers.compareVersions(probe.version, VERSION) else -1
        when {
            !probe.installed -> { log("TOOLKIT_MISSING; installing v$VERSION"); uploadToolkit(handle) }
            comparison > 0 -> error("Remote toolkit v${probe.version} is newer; use a matching or newer Android client")
            comparison == 0 && !probe.complete -> error("Remote v$VERSION is incomplete. Explicitly uninstall with action 13 before reinstalling")
            comparison == 0 && (probe.buildRevision > BUILD_REVISION || (probe.buildRevision == BUILD_REVISION && probe.buildId != BUILD_ID)) -> error("Remote v$VERSION build is newer or different; downgrade refused")
            comparison == 0 && probe.buildRevision == BUILD_REVISION && probe.buildId == BUILD_ID -> log("TOOLKIT_SAME_BUILD; upload and bootstrap skipped")
            else -> { log("TOOLKIT_UPGRADE ${probe.version.ifBlank { "missing" }} -> $VERSION"); uploadToolkit(handle) }
        }

        val domain = required("Cover domain", "Type the cover domain yourself (no default)") { Validation.validDomain(it) }.lowercase()
        val email = required("Let's Encrypt email", "Type the certificate email yourself (no default)") { Validation.validEmail(it) }
        val templates = checked(handle, "bash $REMOTE_ROOT/linux/05b-cover-site-polished.sh --list", emit = false)
        log(templates.stdout.trim())
        val template = required("Cover template", "R=random, A=stable per domain, or 1-15", "R") { Validation.normalizeTemplate(it) != null }
        val normalizedTemplate = requireNotNull(Validation.normalizeTemplate(template))
        val publicIpResult = checked(handle, "ip=\$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); [ -n \"\$ip\" ] || ip=\$(hostname -I | awk '{print \$1}'); printf '%s\\n' \"\$ip\"", emit = false)
        val publicIp = publicIpResult.stdout.lines().map { it.trim() }.firstOrNull { runCatching { InetAddress.getByName(it) is Inet4Address }.getOrDefault(false) }
            ?: error("Could not determine the VPS public IPv4")
        waitForDns(domain, publicIp)

        val autoInput = "DOMAIN_B64=${Base64.encodeToString(domain.toByteArray(), Base64.NO_WRAP)}\n" +
            "EMAIL_B64=${Base64.encodeToString(email.toByteArray(), Base64.NO_WRAP)}\nLANG=zh\n"
        handle.upload(autoInput.toByteArray(), "proxy-runbook-auto-input", "/tmp", "0600")
        val command = "PROXY_RUNBOOK_LOGIN_USER=${SshHandle.shellQuote(handle.target.user)} PROXY_RUNBOOK_SSH_KEY_INSTALLED=1 PROXY_RUNBOOK_ASSUME_DEFAULTS=1 PROXY_RUNBOOK_GUI_MODE=1 PROXY_RUNBOOK_LANG=zh PROXY_RUNBOOK_COVER_TEMPLATE=${SshHandle.shellQuote(normalizedTemplate)} PROXY_RUNBOOK_AUTO_INPUT=/tmp/proxy-runbook-auto-input bash $REMOTE_ROOT/linux/00-auto-install-or-optimize.sh"
        val result = checked(handle, command, interactive = true)
        check(result.ok) { "remote convergence returned ${result.exitCode}" }
        showHandoff(handle)
        if (confirmYes("Prune redundant remote backups and retain one verified current-config backup before opening the panel?", false, allowNo = true)) {
            pruneBackups(handle, exactConfirmation = false)
        }
        return if (confirmYes("Open the 3x-ui panel through a localhost SSH tunnel now?", true, allowNo = true)) openPanel(handle) else false
    }

    private suspend fun uploadToolkit(handle: SshHandle) {
        log("Uploading embedded proxy-runbook v$VERSION...")
        val bytes = context.assets.open(TOOLKIT_ASSET).use { it.readBytes() }
        require(bytes.size > 128) { "embedded toolkit is empty" }
        handle.upload(bytes, TOOLKIT_ARCHIVE, "/tmp", "0600")
        val bootstrap = "mkdir -p /opt; rm -rf ${SshHandle.shellQuote(INSTALL_ROOT)}; tar -xzf ${SshHandle.shellQuote("/tmp/$TOOLKIT_ARCHIVE")} -C /opt; PROXY_RUNBOOK_LOGIN_USER=${SshHandle.shellQuote(handle.target.user)} PROXY_RUNBOOK_SSH_KEY_INSTALLED=1 bash $INSTALL_ROOT/linux/00-bootstrap-toolkit.sh"
        checked(handle, bootstrap, interactive = true)
        val verified = probe(handle)
        check(verified.installed && verified.complete && verified.version == VERSION && verified.buildId == BUILD_ID && verified.buildRevision == BUILD_REVISION) {
            "bootstrap returned success but the exact v$VERSION build probe is missing"
        }
        log("TOOLKIT_INSTALL_VERIFIED")
    }

    private suspend fun probe(handle: SshHandle): ToolkitProbe {
        val command = """
            printf '%s\n' '${ProtocolParsers.TOOLKIT_BEGIN}'
            if [ -r $REMOTE_ROOT/TOOLKIT_VERSION ]; then
              version=${'$'}(head -n1 $REMOTE_ROOT/TOOLKIT_VERSION | tr -d '\r')
              build=${'$'}(head -n1 $REMOTE_ROOT/TOOLKIT_BUILD_ID 2>/dev/null | tr -d '\r' || true)
              revision=${'$'}(head -n1 $REMOTE_ROOT/TOOLKIT_BUILD_REVISION 2>/dev/null | tr -d '\r' || true)
              complete=0
              test -x $REMOTE_ROOT/linux/00-auto-install-or-optimize.sh && test -x $REMOTE_ROOT/linux/18-panel-metadata.sh && test -x $REMOTE_ROOT/linux/22-dismantle-managed-node.sh && test -s $REMOTE_ROOT/templates/cover-sites/MANIFEST.tsv && complete=1
              printf 'TOOLKIT_PRESENT=1\nTOOLKIT_VERSION=%s\nTOOLKIT_BUILD_ID=%s\nTOOLKIT_BUILD_REVISION=%s\nTOOLKIT_COMPLETE=%s\n' "${'$'}version" "${'$'}build" "${'$'}revision" "${'$'}complete"
            else
              printf 'TOOLKIT_PRESENT=0\n'
            fi
            printf '%s\n' '${ProtocolParsers.TOOLKIT_END}'
        """.trimIndent()
        val result = checked(handle, command, emit = false)
        return ProtocolParsers.toolkit(result.stdout)
    }

    private suspend fun ensureToolkit(handle: SshHandle) {
        val probe = probe(handle)
        check(probe.installed) { "Remote toolkit is missing; run action 1 first" }
        check(probe.complete) { "Remote toolkit is incomplete; use action 13, then action 1" }
        check(probe.version == VERSION) { "Remote toolkit v${probe.version} does not match Android client v$VERSION; run action 1 when upgrading, or use a matching client" }
        check(probe.buildRevision == BUILD_REVISION && probe.buildId == BUILD_ID) { "Remote v$VERSION build does not match; run action 1 to update an older build, or use a newer client" }
    }

    private suspend fun showHandoff(handle: SshHandle) {
        val command = "printf '%s\\n' '${ProtocolParsers.HANDOFF_BEGIN}'; cat /root/.config/proxy-runbook/HANDOFF-SECRETS.txt 2>/dev/null || true; printf '%s\\n' '${ProtocolParsers.HANDOFF_END}'"
        val result = checked(handle, command, emit = false)
        val handoff = ProtocolParsers.handoff(result.stdout)
        _state.update { it.copy(secretHandoff = handoff) }
        log("CREDENTIAL_HANDOFF_VALIDATED; secrets are shown only in the protected handoff panel")
    }

    private suspend fun openPanel(handle: SshHandle): Boolean {
        ensureToolkit(handle)
        val meta = ProtocolParsers.panel(checked(handle, "bash $REMOTE_ROOT/linux/18-panel-metadata.sh", emit = false).stdout)
        val forward = handle.openLocalForward(meta.port)
        val url = "http://127.0.0.1:${forward.localPort}${meta.path}"
        TunnelRegistry.install(context, handle, forward, url)
        activeHandle = null
        _state.update { it.copy(panelUrl = url) }
        log("PANEL_TUNNEL_ACTIVE url=$url source=${meta.source}")
        return true
    }

    private suspend fun rotateVpsPassword(handle: SshHandle) {
        val user = required("VPS user", "Account whose login password will be rotated", handle.target.user) { Validation.validUser(it) }
        confirmYes("Generate and immediately apply a high-entropy password for $user?", false)
        checked(handle, "source $REMOTE_ROOT/linux/lib-handoff.sh; handoff_begin_run; bash $REMOTE_ROOT/linux/01a-rotate-vps-password.sh ${SshHandle.shellQuote(user)}")
        showHandoff(handle)
    }

    private suspend fun rotatePanelCredentials(handle: SshHandle) {
        confirmYes("Rotate the 3x-ui username/password? Existing sessions will be logged out and 2FA may be disabled.", false)
        checked(handle, "source $REMOTE_ROOT/linux/lib-handoff.sh; handoff_begin_run; bash $REMOTE_ROOT/linux/03c-rotate-panel-credentials.sh")
        showHandoff(handle)
    }

    private suspend fun optimizeCover(handle: SshHandle) {
        val env = ProtocolParsers.kv(checked(handle, "cat /etc/proxy-runbook/public.env", emit = false).stdout)
        val domain = env["COVER_DOMAIN"].orEmpty()
        require(Validation.validDomain(domain)) { "No valid runtime cover domain; run action 1 first" }
        log(checked(handle, "bash $REMOTE_ROOT/linux/05b-cover-site-polished.sh --list", emit = false).stdout.trim())
        val template = required("Cover template", "R=random, A=stable, 1-15=exact", "R") { Validation.normalizeTemplate(it) != null }
        val selected = requireNotNull(Validation.normalizeTemplate(template))
        checked(handle, "bash $REMOTE_ROOT/linux/05b-cover-site-polished.sh ${SshHandle.shellQuote(domain)} auto ${SshHandle.shellQuote(selected)}; bash $REMOTE_ROOT/linux/05c-optimize-cover-backend.sh ${SshHandle.shellQuote(domain)}", interactive = true)
    }

    private suspend fun emergencyReport(handle: SshHandle) {
        val result = checked(handle, "bash $REMOTE_ROOT/linux/10-emergency-network-dump.sh")
        val remote = Regex("/root/emergency-network-[0-9]{8}-[0-9]{6}\\.txt").find(result.stdout)?.value ?: error("report path was not recognized")
        val data = handle.downloadBytes(remote)
        val directory = File(context.filesDir, "reports").apply { mkdirs() }
        val file = File(directory, remote.substringAfterLast('/'))
        file.writeBytes(data)
        _state.update { it.copy(downloadedFile = file.absolutePath) }
        log("REPORT_DOWNLOADED_TO_APP_PRIVATE_STORAGE ${file.name}")
    }

    private suspend fun rotateManagedKey(handle: SshHandle) {
        val old = managedKeys.get(handle.target.id) ?: error("No bound managed key exists; choose managed-key login once to bind one")
        confirmYes("Generate and verify a new Ed25519 key before removing the old public key?", false)
        val replacement = managedKeys.generate(handle.target.id)
        installPublicKey(handle, replacement.publicKeyOpenSsh)
        managedKeys.archive(handle.target.id)
        managedKeys.put(replacement)
        try {
            ssh.connect(handle.target, SessionCredential(AuthMode.MANAGED_KEY)).use { verified ->
                val check = verified.exec("printf SSH_KEY_OK", root = false)
                require(check.ok && check.stdout.trim() == "SSH_KEY_OK")
            }
        } catch (error: Throwable) {
            managedKeys.delete(handle.target.id, KeyStatus.BOUND)
            managedKeys.restore(handle.target.id)
            removePublicKey(handle, replacement.publicKeyOpenSsh)
            throw IllegalStateException("Replacement key failed verification; old key restored", error)
        }
        removePublicKey(handle, old.publicKeyOpenSsh)
        _state.update { it.copy(secretHandoff = "SSH_PRIVATE_KEY\n${replacement.privateKeyOpenSsh}\nSSH_PUBLIC_KEY\n${replacement.publicKeyOpenSsh}") }
        log("SSH_KEY_ROTATED_AND_VERIFIED")
    }

    private suspend fun installPublicKey(handle: SshHandle, publicKey: String) {
        val encoded = Base64.encodeToString(publicKey.toByteArray(), Base64.NO_WRAP)
        val command = "umask 077; mkdir -p \"\$HOME/.ssh\"; touch \"\$HOME/.ssh/authorized_keys\"; chmod 700 \"\$HOME/.ssh\"; chmod 600 \"\$HOME/.ssh/authorized_keys\"; key=\$(printf %s ${SshHandle.shellQuote(encoded)} | base64 -d); grep -qxF \"\$key\" \"\$HOME/.ssh/authorized_keys\" || printf '%s\\n' \"\$key\" >> \"\$HOME/.ssh/authorized_keys\""
        val result = handle.exec(command, root = false, log = ::log)
        check(result.ok) { "public-key install failed (${result.exitCode})" }
    }

    private suspend fun removePublicKey(handle: SshHandle, publicKey: String) {
        val encoded = Base64.encodeToString(publicKey.toByteArray(), Base64.NO_WRAP)
        val command = "key=\$(printf %s ${SshHandle.shellQuote(encoded)} | base64 -d); file=\"\$HOME/.ssh/authorized_keys\"; tmp=\$(mktemp); grep -vxF \"\$key\" \"\$file\" > \"\$tmp\" || true; cat \"\$tmp\" > \"\$file\"; rm -f \"\$tmp\"; chmod 600 \"\$file\""
        val result = handle.exec(command, root = false, log = ::log)
        check(result.ok) { "public-key removal failed (${result.exitCode})" }
    }

    private suspend fun uninstallToolkit(handle: SshHandle) {
        val confirmation = required("Uninstall toolkit", "Type uppercase UNINSTALL. Node services, configs, credentials, and backups are preserved.") { it == "UNINSTALL" }
        check(confirmation == "UNINSTALL")
        val command = """
            set -Eeuo pipefail
            dirs=(/opt/proxy-runbook-v0.5 /opt/proxy-runbook-v0.6 /opt/proxy-runbook-v0.6.1 /opt/proxy-runbook-v0.6.2 /opt/proxy-runbook-v0.6.5 /opt/proxy-runbook-v0.6.6 /opt/proxy-runbook-v0.7.1 /opt/proxy-runbook-v0.7.4 /opt/proxy-runbook-v0.8.2 /opt/proxy-runbook-v0.8.4 /opt/proxy-runbook-v0.8.5 /opt/proxy-runbook-v0.8.6 /opt/proxy-runbook-v0.9.0)
            for target in "${'$'}{dirs[@]}"; do [ ! -e "${'$'}target" ] || { [ -d "${'$'}target" ] && [ ! -L "${'$'}target" ]; } || exit 61; done
            [ ! -e /opt/proxy-runbook-current ] || [ -L /opt/proxy-runbook-current ] || exit 62
            printf 'PROXY_RUNBOOK_UNINSTALL_BEGIN\n'
            rm -f /opt/proxy-runbook-current /usr/local/sbin/proxy-node /tmp/proxy-runbook-toolkit-v*.tar.gz
            for target in "${'$'}{dirs[@]}"; do [ ! -d "${'$'}target" ] || rm -rf -- "${'$'}target"; done
            printf 'PRESERVED=NODE_SERVICES_AND_CONFIG\nPROXY_RUNBOOK_UNINSTALL_END\n'
        """.trimIndent()
        val result = checked(handle, command)
        require("PROXY_RUNBOOK_UNINSTALL_BEGIN" in result.stdout && "PROXY_RUNBOOK_UNINSTALL_END" in result.stdout) { "complete uninstall markers were missing" }
    }

    private suspend fun pruneBackups(handle: SshHandle, exactConfirmation: Boolean = true) {
        if (exactConfirmation) required("Prune backups", "Type uppercase CLEAN to create one verified current-config backup and remove known older managed backups.") { it == "CLEAN" }
        val result = checked(handle, "bash $REMOTE_ROOT/linux/19-prune-backups-current-config.sh", interactive = true)
        listOf("CURRENT_CONFIG_BACKUP_OK", "OLD_REMAINING=0", "CURRENT_CONFIG_ARCHIVES=1", "MANIFEST_VERIFY_OK=1", "SERVICES_UNCHANGED=1").forEach { marker -> require(marker in result.stdout) { "cleanup marker $marker is missing" } }
    }

    private suspend fun performanceProfile(handle: SshHandle) {
        log(checked(handle, "bash $REMOTE_ROOT/linux/20-adaptive-performance.sh --detect", emit = false).stdout.trim())
        val choice = required("Performance profile", "0=detect only, 1=auto, 2=low, 3=standard, 4=high, 5=rollback", "0") { it in setOf("0", "1", "2", "3", "4", "5") }
        val argument = mapOf("1" to "--apply auto", "2" to "--apply low", "3" to "--apply standard", "4" to "--apply high", "5" to "--rollback")[choice] ?: return
        if (choice == "5") confirmYes("Restore the latest performance backup?", false)
        checked(handle, "bash $REMOTE_ROOT/linux/20-adaptive-performance.sh $argument", interactive = true)
    }

    private suspend fun trafficEstimate(handle: SshHandle) {
        var status = checked(handle, "bash $REMOTE_ROOT/linux/21-traffic-status.sh --status")
        if ("VNSTAT_INSTALLED=1" !in status.stdout || "VNSTAT_DATABASE_READY=1" !in status.stdout) {
            if (!confirmYes("vnStat is not ready. Install/initialize this low-overhead counter?", true, allowNo = true)) return
            checked(handle, "bash $REMOTE_ROOT/linux/21-traffic-status.sh --install", interactive = true)
            status = checked(handle, "bash $REMOTE_ROOT/linux/21-traffic-status.sh --status")
        }
        log(status.stdout.trim())
        checked(handle, "bash $REMOTE_ROOT/linux/21-traffic-status.sh --json")
        log("NOTICE: SSH/vnStat counters are estimates and do not replace provider billing data.")
    }

    private suspend fun dismantle(handle: SshHandle) {
        val plan = checked(handle, "bash $REMOTE_ROOT/linux/22-dismantle-managed-node.sh --plan")
        require("PNA_DISMANTLE_PLAN_BEGIN" in plan.stdout && "PNA_DISMANTLE_PLAN_END" in plan.stdout) { "complete dismantle plan markers are missing" }
        required("Full dismantle", "Type uppercase RESTORE ORIGINAL. A rescue archive is downloaded before any removal.") { it == "RESTORE ORIGINAL" }
        val legacy = "RESTORE_GRADE=LEGACY_UNCERTAIN" in plan.stdout
        if (legacy) required("Legacy limitation", "Type uppercase LEGACY FULL RESTORE to accept bounded removal without a byte-for-byte baseline.") { it == "LEGACY FULL RESTORE" }
        val backup = checked(handle, "bash $REMOTE_ROOT/linux/01-safe-backup.sh")
        require("BACKUP_OK" in backup.stdout) { "pre-dismantle backup failed" }
        val remote = Regex("/root/proxy-node-backup-[0-9]{8}-[0-9]{6}\\.tar\\.gz").find(backup.stdout)?.value ?: error("rescue archive path missing")
        val bytes = handle.downloadBytes(remote)
        require(bytes.size > 1024) { "downloaded rescue archive is unexpectedly small" }
        val directory = File(context.filesDir, "rescue").apply { mkdirs() }
        val file = File(directory, remote.substringAfterLast('/')).apply { writeBytes(bytes) }
        _state.update { it.copy(downloadedFile = file.absolutePath) }
        log("RESCUE_ARCHIVE_DOWNLOADED ${file.name}")
        val env = if (legacy) "PNA_DISMANTLE_CONFIRM=RESTORE_ORIGINAL PNA_LEGACY_FULL=1" else "PNA_DISMANTLE_CONFIRM=RESTORE_ORIGINAL"
        val result = checked(handle, "$env bash $REMOTE_ROOT/linux/22-dismantle-managed-node.sh --execute", interactive = true)
        listOf("PNA_DISMANTLE_BEGIN", "SSH_ACCESS_PRESERVED=1", "PRESERVED_SHARED_BASE_PACKAGES=1", "PNA_DISMANTLE_END").forEach { require(it in result.stdout) { "dismantle marker $it missing; rescue retained" } }
    }

    private suspend fun checked(handle: SshHandle, command: String, interactive: Boolean = false, emit: Boolean = true) =
        handle.exec(command, root = true, interactive = interactive, log = if (emit) ::log else { _ -> }).also { result ->
            check(result.ok) { "remote command failed (exit ${result.exitCode}): ${(result.stderr.ifBlank { result.stdout }).takeLast(1200)}" }
        }

    private suspend fun required(title: String, message: String, default: String = "", valid: (String) -> Boolean): String {
        while (true) {
            val answer = prompts.ask(title, message, PromptKind.TEXT, defaultValue = default).trim().ifEmpty { default }
            if (valid(answer)) return answer
            log("INPUT_REJECTED: $title")
        }
    }

    private suspend fun confirmYes(message: String, defaultYes: Boolean, allowNo: Boolean = false): Boolean {
        val answer = prompts.ask("Confirmation", message, PromptKind.YES_NO, defaultValue = if (defaultYes) "y" else "n").trim().lowercase()
        val yes = if (answer.isBlank()) defaultYes else answer in setOf("y", "yes", "是")
        if (!yes && !allowNo) throw CancellationException("confirmation declined")
        return yes
    }

    private suspend fun waitForDns(domain: String, publicIp: String) {
        while (true) {
            val matches = runCatching { InetAddress.getAllByName(domain).any { it.hostAddress == publicIp } }.getOrDefault(false)
            if (matches) { log("DNS_OK $domain -> $publicIp"); return }
            val answer = prompts.ask("DNS not ready", "Create an A record for $domain -> $publicIp (DNS only). Press Enter to re-check or type q to cancel.", PromptKind.TEXT)
            if (answer.trim().equals("q", true)) throw CancellationException("DNS verification cancelled")
        }
    }

    private suspend fun log(line: String) {
        val safe = line.replace(Regex("(?i)(password|api[_ -]?key|token|private[_ -]?key)=\\S+"), "$1=<redacted>")
        _state.update { current -> current.copy(log = (current.log + safe).takeLast(6000), prompt = prompts.prompt.value) }
    }

    private fun safeError(error: Throwable): String = (error.message ?: error.javaClass.simpleName).replace(Regex("(?i)(password|api[_ -]?key|token|private[_ -]?key)=\\S+"), "$1=<redacted>")

    companion object {
        const val VERSION = "0.9.0"
        const val BUILD_ID = "20260822-full-dismantle-v5"
        const val BUILD_REVISION = 5
        const val REMOTE_ROOT = "/opt/proxy-runbook-current"
        const val INSTALL_ROOT = "/opt/proxy-runbook-v0.9.0"
        const val TOOLKIT_ASSET = "proxy-runbook-toolkit-v0.9.0.tgz"
        const val TOOLKIT_ARCHIVE = "proxy-runbook-toolkit-v0.9.0.tar.gz"
    }
}
