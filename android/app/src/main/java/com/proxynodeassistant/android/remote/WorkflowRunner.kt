package com.proxynodeassistant.android.remote

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import com.proxynodeassistant.android.core.PromptBroker
import com.proxynodeassistant.android.core.Product
import com.proxynodeassistant.android.core.Validation
import com.proxynodeassistant.android.data.ManagedKeyRepository
import com.proxynodeassistant.android.data.HostKeyRepository
import com.proxynodeassistant.android.data.StableNodeIdentityRepository
import com.proxynodeassistant.android.data.DeviceIdentityRepository
import com.proxynodeassistant.android.data.DriveAdminCapability
import com.proxynodeassistant.android.data.DriveAdminCapabilityRepository
import com.proxynodeassistant.android.data.TargetRepository
import com.proxynodeassistant.android.model.ActionSpec
import com.proxynodeassistant.android.model.AuthMode
import com.proxynodeassistant.android.model.HostKeyRecord
import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.Language
import com.proxynodeassistant.android.model.NodeTarget
import com.proxynodeassistant.android.model.PromptKind
import com.proxynodeassistant.android.model.RunStatus
import com.proxynodeassistant.android.model.StableNodeIdentity
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
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import com.trilead.ssh2.crypto.fingerprint.KeyFingerprint
import javax.net.ssl.HttpsURLConnection

class WorkflowRunner(
    private val context: Context,
    private val ssh: SshEngine,
    private val managedKeys: ManagedKeyRepository,
	private val hostKeys: HostKeyRepository,
	private val stableNodes: StableNodeIdentityRepository,
	private val deviceIdentity: DeviceIdentityRepository,
	private val driveAdminCapabilities: DriveAdminCapabilityRepository,
    private val targets: TargetRepository,
    private val prompts: PromptBroker,
) {
    private class ParkedWorkflow(message: String) : CancellationException(message)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow(WorkflowUiState())
    val state: StateFlow<WorkflowUiState> = _state.asStateFlow()
    private var job: Job? = null
    @Volatile private var activeHandle: SshHandle? = null
    @Volatile private var language: Language = Language.ZH

    fun run(action: ActionSpec, target: NodeTarget, authMode: AuthMode, suppliedPassword: String? = null, language: Language = Language.ZH) {
        check(job?.isActive != true) { "A workflow is already running" }
        this.language = language
        _state.value = WorkflowUiState(RunStatus.CONNECTING, action, target, startedAtEpochMs = System.currentTimeMillis())
        job = scope.launch {
            var handle: SshHandle? = null
            var tunnelTransferred = false
            try {
                targets.remember(target)
                log("TNA_ANDROID_WORKFLOW action=${action.code} target=${target.id}")
				if (action.code == "23") {
					check(authMode == AuthMode.MANAGED_KEY) { tr("IP 重绑定必须选择旧节点的长期 key；不会生成替代 key", "IP rebind requires the old node's managed key; no replacement key is generated") }
					handle = rebindPublicIp(target)
					activeHandle = handle
					_state.update { it.copy(status = RunStatus.SUCCEEDED) }
					return@launch
				}
				handle = connect(target, authMode, suppliedPassword)
                activeHandle = handle
                _state.update { it.copy(status = RunStatus.RUNNING) }
                tunnelTransferred = execute(action.code.uppercase(), handle)
                _state.update { it.copy(status = RunStatus.SUCCEEDED) }
            } catch (parked: ParkedWorkflow) {
                _state.update { it.copy(status = RunStatus.CANCELLED, error = parked.message) }
            } catch (_: CancellationException) {
                _state.update { it.copy(status = RunStatus.CANCELLED, error = tr("操作已安全取消", "Operation cancelled safely")) }
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

    fun runLocalDeviceJoin(action: ActionSpec, language: Language = Language.ZH) {
        check(action.code.equals("J", true))
        check(job?.isActive != true) { "A workflow is already running" }
        this.language = language
        _state.value = WorkflowUiState(RunStatus.RUNNING, action, startedAtEpochMs = System.currentTimeMillis())
        job = scope.launch {
            try {
                joinDeviceWithInvitation()
                _state.update { it.copy(status = RunStatus.SUCCEEDED) }
            } catch (_: CancellationException) {
                _state.update { it.copy(status = RunStatus.CANCELLED, error = tr("操作已安全取消", "Operation cancelled safely")) }
            } catch (error: Throwable) {
                log("FAIL_CLOSED: ${safeError(error)}")
                _state.update { it.copy(status = RunStatus.FAILED, error = safeError(error)) }
            } finally {
                prompts.cancel()
                activeHandle = null
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
            return ssh.connect(target, SessionCredential(AuthMode.MANAGED_KEY), language)
        }
        val password = suppliedPassword?.takeIf { it.isNotBlank() } ?: prompts.ask(
            tr("SSH 登录密码", "SSH password"),
            tr("请输入 ${target.id} 的当前密码。密码只进入本次 SSH 认证交换，不写日志、不保存。", "Enter the current password for ${target.id}. It is sent only to the live SSH authentication exchange and is never logged or saved."),
            PromptKind.SECRET,
        )
        require(password.isNotEmpty()) { tr("SSH 密码不能为空", "SSH password cannot be empty") }
        log("AUTH_MODE=TEMPORARY_PASSWORD")
        val handle = ssh.connect(target, SessionCredential(AuthMode.TEMPORARY_PASSWORD, password), language)
        if (mode == AuthMode.MANAGED_KEY) {
            val answer = prompts.ask(
                tr("是否绑定此节点？", "Bind this node?"),
                tr("密码登录已成功。是否生成此节点独享的 Ed25519 密钥，并使用 Android Keystore 加密保存？[y/N]", "Password login succeeded. Bind a new node-specific Ed25519 key in Android Keystore? [y/N]"),
                PromptKind.YES_NO,
                defaultValue = "n",
            )
            if (answer.equals("y", true) || answer.equals("yes", true)) return bindNewKey(handle)
        }
        return handle
    }

    private suspend fun bindNewKey(handle: SshHandle): SshHandle {
        val record = managedKeys.generate(handle.target.id)
        installPublicKey(handle, record.publicKeyOpenSsh)
        managedKeys.put(record)
        var verified: SshHandle? = null
        try {
            verified = ssh.connect(handle.target, SessionCredential(AuthMode.MANAGED_KEY), language)
            val result = verified.exec("printf SSH_KEY_OK", root = false)
            check(result.ok && result.stdout.trim() == "SSH_KEY_OK") { "new SSH key did not verify" }
        } catch (error: Throwable) {
            runCatching { verified?.close() }
            managedKeys.delete(handle.target.id, KeyStatus.BOUND)
            removePublicKey(handle, record.publicKeyOpenSsh)
            throw IllegalStateException("New key verification failed; the key was rolled back", error)
        }
        _state.update { it.copy(secretHandoff = "SSH_PRIVATE_KEY\n${record.privateKeyOpenSsh}\nSSH_PUBLIC_KEY\n${record.publicKeyOpenSsh}") }
        log("SSH_KEY_BOUND_AND_VERIFIED")
        log("SSH_SESSION_SWITCHED_TO_MANAGED_KEY")
        runCatching { handle.close() }
        return checkNotNull(verified)
    }

    private suspend fun execute(code: String, handle: SshHandle): Boolean = when (code) {
        "1" -> deploy(handle)
        "2" -> openPanel(handle)
        "3" -> { ensureToolkit(handle); checked(handle, "bash $REMOTE_ROOT/linux/16-auto-diagnose.sh --protocol-v1"); false }
        "4" -> { ensureToolkit(handle); confirmYes(tr("先备份，再执行可确定的安全修复？", "Back up and run deterministic safe repair?"), false); checked(handle, "bash $REMOTE_ROOT/linux/17-safe-auto-repair.sh", interactive = true); false }
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
        "19" -> { ensureToolkit(handle); securityEvents(handle); false }
		"20" -> { ensureToolkit(handle); deviceAdmission(handle); false }
        "21" -> { ensureToolkit(handle); privateDrive(handle) }
        "22" -> { ensureToolkit(handle); cdnXhttpControl(handle); false }
		"23" -> error("operation 23 uses the stable-endpoint bootstrap before the ordinary remote runner")
        "T" -> { ensureToolkit(handle); trafficEstimate(handle); log("Provider API profiles are managed from the local Provider screen."); false }
        else -> error(tr("操作 $code 属于本地功能或远端执行器暂不支持", "Action $code is local or unsupported in the remote runner"))
    }

    private suspend fun deploy(handle: SshHandle): Boolean {
        val probe = probe(handle)
        val comparison = if (probe.installed) ProtocolParsers.compareVersions(probe.version, VERSION) else -1
        when {
            !probe.installed -> { log("TOOLKIT_MISSING; installing v$VERSION"); uploadToolkit(handle) }
            comparison > 0 -> error(tr("远端工具包 v${probe.version} 更新，请改用同版或更新的 Android 客户端", "Remote toolkit v${probe.version} is newer; use a matching or newer Android client"))
            comparison == 0 && !probe.complete -> { log("TOOLKIT_SAME_VERSION_INCOMPLETE; repairing in place"); uploadToolkit(handle) }
            comparison == 0 && (probe.buildRevision > BUILD_REVISION || (probe.buildRevision == BUILD_REVISION && probe.buildId != BUILD_ID)) -> error(tr("远端 v$VERSION 构建更新或不同，已拒绝降级", "Remote v$VERSION build is newer or different; downgrade refused"))
            comparison == 0 && probe.buildRevision == BUILD_REVISION && probe.buildId == BUILD_ID -> log("TOOLKIT_SAME_BUILD; upload and bootstrap skipped")
            else -> { log("TOOLKIT_UPGRADE ${probe.version.ifBlank { "missing" }} -> $VERSION"); uploadToolkit(handle) }
        }
		recoverInterruptedInstallTransaction(handle)
        captureOriginalBaseline(handle)
		ensureInstallNodeIdentity(handle, probe)
        val topology = chooseTopology(handle)
        val (domain, email) = topology.baseDomainEmail()
        val templates = checked(handle, "bash $REMOTE_ROOT/linux/05b-cover-site-polished.sh --list", emit = false)
        log(templates.stdout.trim())
        val template = required(tr("伪装站模板", "Cover template"), tr("R=随机，A=按域名稳定选择，或输入 1—15 指定模板", "R=random, A=stable per domain, or 1-15"), "R") { Validation.normalizeTemplate(it) != null }
        val normalizedTemplate = requireNotNull(Validation.normalizeTemplate(template))
        val publicIpResult = checked(handle, "ip=\$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); [ -n \"\$ip\" ] || ip=\$(hostname -I | awk '{print \$1}'); printf '%s\\n' \"\$ip\"", emit = false)
        val publicIp = publicIpResult.stdout.lines().map { it.trim() }.firstOrNull { runCatching { InetAddress.getByName(it) is Inet4Address }.getOrDefault(false) }
            ?: error(tr("无法确定 VPS 公网 IPv4", "Could not determine the VPS public IPv4"))
        if (topology.mode == TopologyMode.ORANGE) waitForOrangeDns(domain) else waitForDns(domain, publicIp)
        if (topology.mode == TopologyMode.DUAL) waitForOrangeDns(topology.orangeDomain)
        if (topology.mode != TopologyMode.GRAY) guideCloudflareCertificatePrerequisites(topology.orangeDomain)

        val autoInput = "DOMAIN_B64=${Base64.encodeToString(domain.toByteArray(), Base64.NO_WRAP)}\n" +
            "EMAIL_B64=${Base64.encodeToString(email.toByteArray(), Base64.NO_WRAP)}\nLANG=zh\n"
        handle.upload(autoInput.toByteArray(), "text-node-assistant-auto-input", "/tmp", "0600")
        val transactionId = beginInstallTransaction(handle)
        var transactionActive = true
        try {
            var driveHandoff = prepareMandatoryDrive(handle)
            val command = "TNA_LOGIN_USER=${SshHandle.shellQuote(handle.target.user)} TNA_SSH_KEY_INSTALLED=1 TNA_ASSUME_DEFAULTS=1 TNA_GUI_MODE=1 TNA_LANG=zh " +
                "TNA_TOPOLOGY_MODE=${SshHandle.shellQuote(topology.mode.value)} TNA_COVER_TEMPLATE=${SshHandle.shellQuote(normalizedTemplate)} " +
                "TNA_AUTO_INPUT=/tmp/text-node-assistant-auto-input bash $REMOTE_ROOT/linux/00-auto-install-or-optimize.sh"
            val result = checked(handle, command, interactive = true)
            check(result.ok) { "remote convergence returned ${result.exitCode}" }
            if (topology.mode != TopologyMode.GRAY) {
                promoteCdnPublicOrigin(handle, topology)
                guideCloudflareOrangeSetup(topology.orangeDomain)
                validateCdnEdge(handle, topology)
                confirmCdnRealClient(handle, topology)
            }
            reconcileTopology(handle, topology)
            finalizeMandatoryDrive(handle, topology.lifecycle())
            ensureCurrentControllerAfterInstall(handle)
            driveHandoff = ensureLocalDriveAdminCapability(handle, driveHandoff)
            showHandoff(handle, driveHandoff)
            commitInstallTransaction(handle, transactionId)
            transactionActive = false
        } finally {
            if (transactionActive) {
                runCatching { rollbackInstallTransaction(handle, transactionId) }
                    .onFailure { log("INSTALL_TRANSACTION_ROLLBACK_FAILED: ${safeError(it)}") }
            }
        }
        if (confirmYes(tr("打开面板前是否整理冗余备份，并只保留一份已验证的当前配置备份？", "Prune redundant remote backups and retain one verified current-config backup before opening the panel?"), false, allowNo = true)) {
            pruneBackups(handle, exactConfirmation = false)
        }
        return if (confirmYes(tr("现在通过本机 SSH 隧道打开 3x-ui 面板？", "Open the 3x-ui panel through a localhost SSH tunnel now?"), true, allowNo = true)) openPanel(handle) else false
    }

    private enum class TopologyMode(val value: String) { GRAY("gray"), ORANGE("orange"), DUAL("dual") }
    private data class TopologyPlan(
        val mode: TopologyMode,
        val grayDomain: String = "",
        val grayEmail: String = "",
        val orangeDomain: String = "",
        val orangeEmail: String = "",
    ) {
        fun baseDomainEmail() = if (mode == TopologyMode.ORANGE) orangeDomain to orangeEmail else grayDomain to grayEmail
        fun lifecycle() = when (mode) {
            TopologyMode.GRAY -> "MANAGED_GRAY_WITH_DRIVE"
            TopologyMode.ORANGE -> "MANAGED_ORANGE_WITH_DRIVE"
            TopologyMode.DUAL -> "MANAGED_DUAL_WITH_DRIVE"
        }
    }

    private suspend fun chooseTopology(handle: SshHandle): TopologyPlan {
        val installed = checked(
            handle,
            "if test -x /usr/local/x-ui/x-ui && test -s /etc/text-node-assistant/deployment-state.env; then echo INSTALLED=1; else echo INSTALLED=0; fi",
            emit = false,
        ).stdout.contains("INSTALLED=1")
        val description = buildString {
            appendLine(tr("必须明确选择线路拓扑，不能直接回车：", "Choose a topology explicitly; blank input is not accepted:"))
            appendLine(tr("[1] 仅灰云：路径短、延迟低；客户端可看到源站 IP。", "[1] Gray only: shorter path and lower latency; clients can see the origin IP."))
            appendLine(tr("[2] 仅橙云：Cloudflare/XHTTP；使用 Cloudflare 免费支持的 8443 端口，需 Full (strict) 和缓存绕过。", "[2] Orange only: Cloudflare/XHTTP; uses Cloudflare's free-plan 8443 edge port, with Full (strict) and cache bypass."))
            appendLine(tr("[3] 双路：两个不同子域名，同时保留直连和 CDN。", "[3] Dual: two distinct hostnames, retaining both direct and CDN routes."))
            if (installed) append(tr("[0] 保持已安装拓扑", "[0] Keep the installed topology"))
        }
        val valid = if (installed) setOf("0", "1", "2", "3") else setOf("1", "2", "3")
        val choice = required(tr("代理线路拓扑", "Proxy topology"), description) { it in valid }
        if (choice == "0") return loadExistingTopology(handle)
        suspend fun domainEmail(label: String): Pair<String, String> {
            val domain = required(label, tr("必须本人输入完整子域名，没有默认值", "Type the full hostname yourself; there is no default")) { Validation.validDomain(it) }.lowercase()
            val email = required(tr("证书通知邮箱", "Certificate email"), tr("必须本人输入有效邮箱，没有默认值", "Type a valid email yourself; there is no default")) { Validation.validEmail(it) }
            return domain to email
        }
        return when (choice) {
            "1" -> domainEmail(tr("Step 1：灰云 / DNS-only 子域名", "Step 1: gray / DNS-only hostname")).let { TopologyPlan(TopologyMode.GRAY, it.first, it.second) }
            "2" -> domainEmail(tr("Step 1：橙云 / Proxied 子域名", "Step 1: orange-cloud / Proxied hostname")).let { TopologyPlan(TopologyMode.ORANGE, orangeDomain = it.first, orangeEmail = it.second) }
            else -> {
                val gray = domainEmail(tr("Step 1：灰云 / DNS-only 子域名", "Step 1: gray / DNS-only hostname"))
                val orange = domainEmail(tr("Step 2：橙云 / Proxied 子域名", "Step 2: orange-cloud / Proxied hostname"))
                require(gray.first != orange.first) { tr("双路必须使用两个不同子域名", "Dual mode requires two different hostnames") }
                TopologyPlan(TopologyMode.DUAL, gray.first, gray.second, orange.first, orange.second)
            }
        }
    }

    private suspend fun loadExistingTopology(handle: SshHandle): TopologyPlan {
        val result = checked(handle, "cat /root/.config/text-node-assistant/topology.env", emit = false)
        val values = ProtocolParsers.kv(result.stdout)
        val mode = when (values["TOPOLOGY_MODE"]) {
            "gray" -> TopologyMode.GRAY
            "orange" -> TopologyMode.ORANGE
            "dual" -> TopologyMode.DUAL
            else -> error(tr("既有节点没有可验证的拓扑记录，请明确选择 1—3", "The existing node has no verifiable topology record; choose 1-3"))
        }
        val plan = TopologyPlan(mode, values["GRAY_DOMAIN"].orEmpty(), values["GRAY_EMAIL"].orEmpty(), values["ORANGE_DOMAIN"].orEmpty(), values["ORANGE_EMAIL"].orEmpty())
        if (mode != TopologyMode.ORANGE) require(Validation.validDomain(plan.grayDomain) && Validation.validEmail(plan.grayEmail))
        if (mode != TopologyMode.GRAY) require(Validation.validDomain(plan.orangeDomain) && Validation.validEmail(plan.orangeEmail))
        require(mode != TopologyMode.DUAL || plan.grayDomain != plan.orangeDomain)
        return plan
    }

    private suspend fun recoverInterruptedInstallTransaction(handle: SshHandle) {
        val status = ProtocolParsers.kv(checked(handle, "bash $REMOTE_ROOT/linux/28a-install-transaction.sh status", emit = false).stdout)
        when (status["TRANSACTION_STATUS"]) {
            "NONE" -> return
            "PREPARING", "ACTIVE", "ROLLING_BACK", "ROLLBACK_FAILED" -> {
                log(tr("检测到上次未提交施工，先恢复事务快照，禁止在半成品上叠加。", "A prior install was not committed; its snapshot will be restored before any new work."))
                val rollback = checked(handle, "bash $REMOTE_ROOT/linux/28a-install-transaction.sh rollback", emit = false)
                require(
                    "TNA_INSTALL_TRANSACTION_ROLLED_BACK=1" in rollback.stdout ||
                        "TNA_INSTALL_TRANSACTION_ROLLBACK=PREPARE_ABORTED" in rollback.stdout ||
                        "TNA_INSTALL_TRANSACTION_ROLLBACK=NOT_NEEDED" in rollback.stdout,
                ) { "Interrupted install rollback did not return complete evidence" }
            }
            else -> error("Unsupported install transaction state: ${status["TRANSACTION_STATUS"]}")
        }
    }

    private suspend fun captureOriginalBaseline(handle: SshHandle) {
        val result = checked(handle, "bash $REMOTE_ROOT/linux/22-dismantle-managed-node.sh --capture-baseline", emit = false)
        require(
            listOf("ORIGINAL_BASELINE_CAPTURED_EXACT", "ORIGINAL_BASELINE_ALREADY_CAPTURED", "ORIGINAL_BASELINE_LEGACY_UNCERTAIN").any { it in result.stdout },
        ) { "Pre-construction baseline capture returned no accepted evidence" }
        log(tr("[GOOD] 原生基线已在网盘、代理、证书和节点身份改动前捕获或复核。", "[GOOD] The native baseline was captured or verified before drive, proxy, certificate, or node-identity changes."))
    }

    private suspend fun beginInstallTransaction(handle: SshHandle): String {
        val result = checked(handle, "bash $REMOTE_ROOT/linux/28a-install-transaction.sh begin standalone 0", emit = false)
        require("TNA_INSTALL_TRANSACTION_BEGAN=1" in result.stdout)
        return ProtocolParsers.kv(result.stdout)["TRANSACTION_ID"].orEmpty().also {
            require(Regex("^tna-install-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$").matches(it))
        }
    }

    private suspend fun rollbackInstallTransaction(handle: SshHandle, transactionId: String) {
        val status = ProtocolParsers.kv(checked(handle, "bash $REMOTE_ROOT/linux/28a-install-transaction.sh status", emit = false).stdout)
        if (status["TRANSACTION_STATUS"] == "NONE") return
        require(status["TRANSACTION_ID"] == transactionId) { "Refusing to roll back another install transaction" }
        val result = checked(handle, "bash $REMOTE_ROOT/linux/28a-install-transaction.sh rollback", emit = false)
        require("TNA_INSTALL_TRANSACTION_ROLLED_BACK=1" in result.stdout)
        log(tr("[GOOD] 未提交施工已恢复到事务前状态。", "[GOOD] Uncommitted construction was restored to its pre-transaction state."))
    }

    private suspend fun commitInstallTransaction(handle: SshHandle, transactionId: String) {
        val status = ProtocolParsers.kv(checked(handle, "bash $REMOTE_ROOT/linux/28a-install-transaction.sh status", emit = false).stdout)
        require(status["TRANSACTION_STATUS"] == "ACTIVE" && status["TRANSACTION_ID"] == transactionId)
        val result = checked(handle, "bash $REMOTE_ROOT/linux/28a-install-transaction.sh commit", emit = false)
        require("TNA_INSTALL_TRANSACTION_COMMITTED=1" in result.stdout)
        log(tr("[GOOD] 菜单 [1] 的全部远端阶段已原子提交。", "[GOOD] Every remote stage of action 1 was committed atomically."))
    }

    private suspend fun waitForOrangeDns(domain: String) {
        while (true) {
            val resolved = runCatching {
                val cloudflare = URL("https://cloudflare-dns.com/dns-query?name=$domain&type=A").openConnection(Proxy.NO_PROXY) as HttpsURLConnection
                cloudflare.setRequestProperty("Accept", "application/dns-json")
                cloudflare.connectTimeout = 10_000
                cloudflare.readTimeout = 10_000
                val first = cloudflare.inputStream.bufferedReader().use { it.readText() }
                cloudflare.disconnect()
                val google = URL("https://dns.google/resolve?name=$domain&type=A").openConnection(Proxy.NO_PROXY) as HttpsURLConnection
                google.connectTimeout = 10_000
                google.readTimeout = 10_000
                val second = google.inputStream.bufferedReader().use { it.readText() }
                google.disconnect()
                Regex("\\\"type\\\"\\s*:\\s*1").containsMatchIn(first) && Regex("\\\"type\\\"\\s*:\\s*1").containsMatchIn(second)
            }.getOrDefault(false)
            if (resolved) return
            val answer = prompts.ask(
                tr("等待橙云 DNS", "Waiting for orange-cloud DNS"),
                tr("为 $domain 创建指向本 VPS 的 A 记录并开启 Proxied。若 Android VPN/TUN 拦截 DNS，请暂停后重试。按 Enter 重检，输入 q 取消。", "Create a Proxied A record for $domain pointing at this VPS. Pause any Android VPN/TUN that intercepts DNS. Press Enter to retry or q to cancel."),
                PromptKind.TEXT,
            )
            if (answer.equals("q", true)) throw CancellationException("ORANGE_DNS_CANCELLED")
        }
    }

    private suspend fun guideCloudflareCertificatePrerequisites(domain: String) {
        val steps = listOf(
            tr("已确认 $domain 的 A 记录指向当前 VPS 并开启橙云 Proxied", "Confirm $domain points to this VPS and is Proxied"),
            tr("该域名没有 Access、Turnstile、质询、Worker 或重定向拦截 /.well-known/acme-challenge/", "No Access, Turnstile, challenge, Worker, or redirect intercepts /.well-known/acme-challenge/"),
            tr("已理解 Universal SSL 只覆盖客户端到边缘；程序仍会用手填邮箱给 VPS 签源站证书，不索取 Cloudflare Token", "Understand Universal SSL covers client-to-edge only; the app still issues the VPS origin certificate with the typed email and never requests a Cloudflare token"),
        )
        steps.forEachIndexed { index, step ->
            val answer = prompts.ask(tr("橙云源站前置 ${index + 1}/${steps.size}", "Orange-origin gate ${index + 1}/${steps.size}"), "$step\n${tr("确认后按 Enter；输入 q 取消", "Press Enter to confirm; type q to cancel")}", PromptKind.TEXT)
            if (answer.equals("q", true)) throw CancellationException("CLOUDFLARE_PREREQUISITE_CANCELLED")
        }
    }

    private suspend fun guideCloudflareOrangeSetup(domain: String) {
        runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(CLOUDFLARE_DNS_DASHBOARD)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        val steps = listOf(
            tr("确认 $domain 的 A 记录为 Proxied 橙云", "Confirm $domain is Proxied"),
            tr("SSL/TLS 已设 Full (strict)，Universal SSL 已激活", "SSL/TLS is Full (strict) and Universal SSL is active"),
            tr("端口：客户端使用 ${domain}:8443（Cloudflare 免费支持，无需 Origin Rule）", "Port: clients use ${domain}:8443 (supported by Cloudflare without an Origin Rule)"),
            tr("Cache Rule：该 hostname 全站 Bypass；没有 Access、质询、重定向或 Worker", "Cache Rule: bypass the hostname; no Access, challenge, redirect, or Worker"),
        )
        steps.forEachIndexed { index, step ->
            val answer = prompts.ask(tr("Cloudflare 设置 ${index + 1}/${steps.size}", "Cloudflare setup ${index + 1}/${steps.size}"), "$step\n${tr("确认后按 Enter；输入 q 取消", "Press Enter to confirm; type q to cancel")}", PromptKind.TEXT)
            if (answer.equals("q", true)) throw CancellationException("CLOUDFLARE_SETUP_CANCELLED")
        }
    }

    private fun randomDrivePassword(): String = ByteArray(30).also(SecureRandom()::nextBytes).let {
        Base64.encodeToString(it, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun randomDriveAdminUsername(): String = ByteArray(6).also(SecureRandom()::nextBytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }.let { "tna-admin-$it" }

    private suspend fun driveStatus(handle: SshHandle): Map<String, String> =
        ProtocolParsers.kv(checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh status", emit = false).stdout)

    private suspend fun prepareMandatoryDrive(handle: SshHandle): String {
        val status = runCatching { driveStatus(handle) }.getOrNull()
        if (status?.get("PRIVATE_DRIVE_STATUS") == "READY" && status["COPYPARTY_SERVICE"] == "active" && status["COPYPARTY_LOOPBACK_LISTENER"] == "1" && Regex("^tna-admin-[0-9a-f]{12}$").matches(status["DRIVE_ADMIN_USERNAME"].orEmpty())) {
            log(tr("强制网盘已就绪；保留现有 admin 身份和用户文件。", "The mandatory drive is ready; its admin identity and user files are preserved."))
            return ""
        }
        val username = randomDriveAdminUsername()
        val password = randomDrivePassword()
        val quota = required(tr("网盘容量", "Drive quota"), tr("推荐 auto；也可输入 1—50 GiB", "Recommended: auto; or enter 1-50 GiB"), "auto") {
            it == "auto" || it.toIntOrNull()?.let { number -> number in 1..50 } == true
        }
        val result = handle.exec(
            "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh install-admin ${SshHandle.shellQuote(username)} ${SshHandle.shellQuote(quota)}",
            root = true,
            stdinBytes = "$password\n".toByteArray(),
            log = ::log,
        )
        check(result.ok && "__TNA_DRIVE_RESULT_END__" in result.stdout) { "Mandatory drive installation failed (${result.exitCode})" }
        return "===== TNA MANDATORY DRIVE ADMIN v0.9.5 =====\nDRIVE_ADMIN_USERNAME=$username\nDRIVE_ADMIN_PASSWORD=$password\nDRIVE_ADMIN_STORAGE=ANDROID_KEYSTORE_ENCRYPTED_APP_VAULT\n================================================="
    }

    private suspend fun finalizeMandatoryDrive(handle: SshHandle, lifecycle: String) {
        val result = checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh finalize-install ${SshHandle.shellQuote(lifecycle)}", emit = false)
        require("TNA_DRIVE_FINALIZED=1" in result.stdout && "DRIVE_REGISTRATION_READY=1" in result.stdout)
    }

    private suspend fun ensureCurrentControllerAfterInstall(handle: SshHandle) {
        val identity = deviceIdentity.loadOrCreate()
        val status = DeviceAdmissionProtocol.parseStatus(checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh status", emit = false).stdout)
        status.devices.firstOrNull { it.deviceId == identity.deviceId }?.let { existing ->
            require(existing.role == "controller" && existing.status == "active") {
                tr("当前设备已登记为 ${existing.role}/${existing.status}，菜单 [1] 不会静默提权", "This device is registered as ${existing.role}/${existing.status}; action 1 will not silently elevate it")
            }
            return
        }
        require(status.activeControllers == 0) {
            tr("节点已有 controller；请先用首页 [J] 响应一次性邀请，菜单 [1] 不会绕过批准", "The node already has a controller. Use home action J with a single-use invitation; action 1 will not bypass approval")
        }
        val label = required(tr("首个 controller 设备名称", "First-controller device label"), tr("1—64 位安全字符", "1-64 safe characters"), "Android Phone") { Regex("^[A-Za-z0-9._ -]{1,64}$").matches(it) }
        val prior = managedKeys.get(handle.target.id)
        val key = prior ?: managedKeys.generate(handle.target.id)
        val input = "\n${identity.publicValue}\n$label\ncontroller\n${identity.encryptionPublic}\n${handle.target.user}\n${normalizeSshPublic(key.publicKeyOpenSsh)}\n\n"
        val result = handle.exec("bash $REMOTE_ROOT/linux/26-device-admission.sh bootstrap-controller", root = true, stdinBytes = input.toByteArray(), log = ::log)
        check(result.ok && "__TNA_DEVICE_BOOTSTRAP_V1_END__" in result.stdout) { "First-controller bootstrap failed (${result.exitCode})" }
        if (prior == null) managedKeys.put(key)
        try {
            verifyManagedDeviceKey(handle.target)
        } catch (error: Throwable) {
            if (prior == null) managedKeys.delete(handle.target.id, KeyStatus.BOUND)
            throw error
        }
        val readback = DeviceAdmissionProtocol.parseStatus(checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh status", emit = false).stdout)
        require(readback.devices.any { it.deviceId == identity.deviceId && it.role == "controller" && it.status == "active" })
        log(tr("当前 Android 已作为首个 controller 完成真实登记。", "This Android device is now the first verified active controller."))
    }

    private suspend fun verifyDriveAdmin(handle: SshHandle, username: String, password: String) {
        val result = handle.exec(
            "bash $REMOTE_ROOT/linux/30-copyparty-account.sh verify ${SshHandle.shellQuote(username)}",
            root = true,
            stdinBytes = "$password\n".toByteArray(),
            log = ::log,
        )
        check(result.ok && "TNA_DRIVE_ACCOUNT_LOGIN_OK" in result.stdout) { "Drive admin credential failed a real login readback" }
    }

    private suspend fun ensureLocalDriveAdminCapability(handle: SshHandle, handoff: String): String {
        val status = DeviceAdmissionProtocol.parseStatus(checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh status", emit = false).stdout)
        val identity = deviceIdentity.loadOrCreate()
        require(status.devices.any { it.deviceId == identity.deviceId && it.role == "controller" && it.status == "active" })
        if (handoff.isNotBlank()) {
            val values = ProtocolParsers.kv(handoff)
            val capability = DriveAdminCapability(status.nodeId, values["DRIVE_ADMIN_USERNAME"].orEmpty(), values["DRIVE_ADMIN_PASSWORD"].orEmpty())
            verifyDriveAdmin(handle, capability.username, capability.password)
            driveAdminCapabilities.put(capability)
            return handoff
        }
        val remote = driveStatus(handle)
        driveAdminCapabilities.get(status.nodeId)?.takeIf { it.username == remote["DRIVE_ADMIN_USERNAME"] }?.let { stored ->
            runCatching { verifyDriveAdmin(handle, stored.username, stored.password) }.getOrNull()?.let { return "" }
        }
        val username = randomDriveAdminUsername()
        val password = randomDrivePassword()
        val quota = remote["PRIVATE_DRIVE_QUOTA_GIB"].orEmpty().takeIf { it.toIntOrNull() != null } ?: "auto"
        val result = handle.exec(
            "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh rotate-admin ${SshHandle.shellQuote(username)} ${SshHandle.shellQuote(quota)}",
            root = true,
            stdinBytes = "$password\n".toByteArray(),
            log = ::log,
        )
        check(result.ok && "__TNA_DRIVE_RESULT_END__" in result.stdout) { "Drive admin rotation failed (${result.exitCode})" }
        verifyDriveAdmin(handle, username, password)
        driveAdminCapabilities.put(DriveAdminCapability(status.nodeId, username, password))
        return "===== TNA MANDATORY DRIVE ADMIN v0.9.5 =====\nDRIVE_ADMIN_USERNAME=$username\nDRIVE_ADMIN_PASSWORD=$password\nDRIVE_ADMIN_STORAGE=ANDROID_KEYSTORE_ENCRYPTED_APP_VAULT\n================================================="
    }

    private fun topologyEnv(topology: TopologyPlan) = "TNA_TARGET_TOPOLOGY=${topology.mode.value} "

    private suspend fun promoteCdnPublicOrigin(handle: SshHandle, topology: TopologyPlan) {
        val domain = topology.orangeDomain
        val email = topology.orangeEmail
        val publicIp = cdnPublicIp(handle)
        val certificate = checked(handle, "bash $REMOTE_ROOT/linux/05h-ensure-cdn-certificate.sh ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(email)}", emit = false)
        require("TNA_CDN_CERTIFICATE_READY=1" in certificate.stdout || "TNA_CDN_CERTIFICATE_ALREADY_VALID=1" in certificate.stdout)
        val create = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh create ${SshHandle.shellQuote(domain)}", emit = false)
        require(listOf("XHTTP_STATUS=READY", "TNA_XHTTP_ALREADY_READY", "TNA_XHTTP_RETARGETED=1").any { it in create.stdout })
        val env = topologyEnv(topology)
        val local = checked(handle, "${env}bash $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh stage-local ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)}", emit = false)
        require("CDN_STAGE_SCOPE=LOCAL_ONLY" in local.stdout)
        val localCheck = checked(handle, "${env}bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)} --local-only", emit = false)
        require("CDN_LOCAL_VALIDATION=PASS" in localCheck.stdout && "PUBLIC_ORIGIN_8443=NOT_ENABLED" in localCheck.stdout)
        val lock = ProtocolParsers.kv(checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh status", emit = false).stdout)
        if (lock["CLOUDFLARE_FIREWALL_APPLIED"] != "1") {
            checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh fetch", emit = false)
            val plan = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh plan ${handle.target.port}", emit = false)
            require("KEEP_PUBLIC_TCP_443_UNCHANGED=1" in plan.stdout && "DENY_OTHER_SOURCES_TCP=8443" in plan.stdout)
            val apply = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh apply", emit = false)
            require("CLOUDFLARE_FIREWALL_APPLIED=1" in apply.stdout && "PUBLIC_TCP_443_POLICY=UNCHANGED" in apply.stdout)
        }
        try {
            val stage = checked(handle, "${env}bash $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh stage ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)}", emit = false)
            require("CDN_STAGE_SCOPE=CLOUDFLARE_ONLY" in stage.stdout)
            val origin = checked(handle, "${env}bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)} --origin-ready", emit = false)
            require("CDN_ORIGIN_VALIDATION=PASS" in origin.stdout)
            verifyDirectOriginBlocked(publicIp)
        } catch (error: Throwable) {
            runCatching { rollbackCdnPublic(handle, domain, publicIp, topology) }
            throw error
        }
    }

    private suspend fun validateCdnEdge(handle: SshHandle, topology: TopologyPlan) {
        val domain = topology.orangeDomain
        val publicIp = cdnPublicIp(handle)
        verifyCloudflareEdge(domain)
        verifyDirectOriginBlocked(publicIp)
        val remote = checked(handle, "${topologyEnv(topology)}bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)} --edge", emit = false)
        require("ORIGIN_RULE_443_TO_8443=NOT_REQUIRED_CLOUDFLARE_STANDARD_PORT" in remote.stdout && "REAL_DEVICE_BROWSE=REQUIRED" in remote.stdout)
        val linkResult = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh link ${SshHandle.shellQuote(domain)} 8443", emit = false)
        val link = ProtocolParsers.kv(linkResult.stdout)["XHTTP_LINK"].orEmpty()
        val profile = ProtocolParsers.cdnXHttpLink(link)
        require(profile.domain == domain && profile.port == 8443)
        _state.update { it.copy(secretHandoff = "===== TNA CDN XHTTP PRODUCTION TEST v0.9.5 =====\nCDN_XHTTP_LINK=$link\nREAL_DEVICE_BROWSE=REQUIRED_BEFORE_COMMIT") }
    }

    private suspend fun confirmCdnRealClient(handle: SshHandle, topology: TopologyPlan) {
        val exact = prompts.ask(
            tr("真机浏览验收", "Real-device browsing gate"),
            tr("把刚显示的 8443 XHTTP 链接导入客户端并真实浏览；成功后输入大写 REAL BROWSE OK。其他输入将回滚整次施工。", "Import the shown 8443 XHTTP link and actually browse through it. Then type uppercase REAL BROWSE OK. Any other input rolls back this installation."),
            PromptKind.EXACT_CONFIRMATION,
            danger = true,
        )
        require(exact == "REAL BROWSE OK") { tr("真机浏览未确认，拒绝提交橙云拓扑", "Real browsing was not confirmed; the orange topology will not be committed") }
        val result = checked(handle, "${topologyEnv(topology)}bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh ${SshHandle.shellQuote(topology.orangeDomain)} ${SshHandle.shellQuote(cdnPublicIp(handle))} --confirm-client", emit = false)
        require("CDN_REAL_CLIENT_CONFIRMED=1" in result.stdout)
    }

    private suspend fun rollbackCdnPublic(handle: SshHandle, domain: String, publicIp: String, topology: TopologyPlan) {
        val result = checked(handle, "${topologyEnv(topology)}bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)} --rollback-public", emit = false)
        require("CDN_PUBLIC_ORIGIN_ROLLED_BACK=1" in result.stdout)
    }

    private suspend fun reconcileTopology(handle: SshHandle, topology: TopologyPlan) {
        val body = listOf(
            "TOPOLOGY_STATE_VERSION=1",
            "TOPOLOGY_MODE=${topology.mode.value}",
            "GRAY_DOMAIN=${topology.grayDomain}",
            "GRAY_EMAIL=${topology.grayEmail}",
            "ORANGE_DOMAIN=${topology.orangeDomain}",
            "ORANGE_EMAIL=${topology.orangeEmail}",
        ).joinToString("\n", postfix = "\n")
        val result = handle.exec(
            "bash $REMOTE_ROOT/linux/28-topology-reconcile.sh ${topology.mode.value} --commit-state",
            root = true,
            stdinBytes = body.toByteArray(),
            log = ::log,
        )
        check(result.ok && "TNA_TOPOLOGY_RECONCILED=1" in result.stdout) { "Topology convergence failed (${result.exitCode})" }
    }

    private suspend fun uploadToolkit(handle: SshHandle) {
        log("Uploading embedded TextNodeAssistant toolkit v$VERSION...")
        val bytes = context.assets.open(TOOLKIT_ASSET).use { it.readBytes() }
        require(bytes.size > 128) { tr("APK 内嵌工具包为空", "embedded toolkit is empty") }
        handle.upload(bytes, TOOLKIT_ARCHIVE, "/tmp", "0600")
        val bootstrap = "mkdir -p /opt; rm -rf ${SshHandle.shellQuote(INSTALL_ROOT)}; tar -xzf ${SshHandle.shellQuote("/tmp/$TOOLKIT_ARCHIVE")} -C /opt; TNA_LOGIN_USER=${SshHandle.shellQuote(handle.target.user)} TNA_SSH_KEY_INSTALLED=1 bash $INSTALL_ROOT/linux/00-bootstrap-toolkit.sh"
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
            root=''; brand=''
            if [ -r $REMOTE_ROOT/TOOLKIT_VERSION ]; then root=$REMOTE_ROOT; brand=TNA
            elif [ -r $LEGACY_REMOTE_ROOT/TOOLKIT_VERSION ]; then root=$LEGACY_REMOTE_ROOT; brand=PNA_LEGACY
            fi
            if [ -n "${'$'}root" ]; then
              version=${'$'}(head -n1 "${'$'}root/TOOLKIT_VERSION" | tr -d '\r')
              build=${'$'}(head -n1 "${'$'}root/TOOLKIT_BUILD_ID" 2>/dev/null | tr -d '\r' || true)
              revision=${'$'}(head -n1 "${'$'}root/TOOLKIT_BUILD_REVISION" 2>/dev/null | tr -d '\r' || true)
              complete=0
              test -x "${'$'}root/linux/00-auto-install-or-optimize.sh" && test -x "${'$'}root/linux/18-panel-metadata.sh" && test -x "${'$'}root/linux/22-dismantle-managed-node.sh" && test -x "${'$'}root/linux/23-node-identity.sh" && test -x "${'$'}root/linux/24-security-baseline.sh" && test -x "${'$'}root/linux/25-security-events.sh" && test -x "${'$'}root/linux/26-device-admission.sh" && test -x "${'$'}root/linux/27-ip-rebind.sh" && test -x "${'$'}root/linux/04f-xhttp-cdn-api.sh" && test -x "${'$'}root/linux/05e-cdn-xhttp-nginx.sh" && test -x "${'$'}root/linux/05f-cloudflare-origin-lock.sh" && test -x "${'$'}root/linux/05g-cdn-xhttp-validate.sh" && test -x "${'$'}root/linux/28-topology-reconcile.sh" && test -x "${'$'}root/linux/28a-install-transaction.sh" && test -x "${'$'}root/linux/29-copyparty-drive.sh" && test -x "${'$'}root/linux/30-copyparty-account.sh" && test -x "${'$'}root/linux/31-copyparty-nginx.sh" && test -s "${'$'}root/THIRD_PARTY_LOCK.env" && test -s "${'$'}root/templates/copyparty/copyparty.conf.in" && test -s "${'$'}root/templates/systemd/text-node-assistant-copyparty.service" && test -s "${'$'}root/templates/nginx/text-node-assistant-copyparty.conf.in" && test -s "${'$'}root/templates/cover-sites/MANIFEST.tsv" && complete=1
              printf 'TOOLKIT_PRESENT=1\nTOOLKIT_BRAND=%s\nTOOLKIT_ROOT=%s\nTOOLKIT_VERSION=%s\nTOOLKIT_BUILD_ID=%s\nTOOLKIT_BUILD_REVISION=%s\nTOOLKIT_COMPLETE=%s\n' "${'$'}brand" "${'$'}root" "${'$'}version" "${'$'}build" "${'$'}revision" "${'$'}complete"
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
        check(probe.installed) { tr("远端工具包不存在，请先执行操作 [1]", "Remote toolkit is missing; run action 1 first") }
        check(probe.complete) { tr("远端工具包不完整，请先执行 [13]，再执行 [1]", "Remote toolkit is incomplete; use action 13, then action 1") }
        check(probe.version == VERSION) { tr("远端工具包 v${probe.version} 与 Android 客户端 v$VERSION 不匹配；升级时执行 [1]，否则使用同版客户端", "Remote toolkit v${probe.version} does not match Android client v$VERSION; run action 1 when upgrading, or use a matching client") }
        check(probe.buildRevision == BUILD_REVISION && probe.buildId == BUILD_ID) { tr("远端 v$VERSION 构建不匹配；旧构建请执行 [1] 更新，更新构建请换新版客户端", "Remote v$VERSION build does not match; run action 1 to update an older build, or use a newer client") }
		syncStableNodeIdentity(handle)
    }

	private suspend fun readStableNodeIdentity(handle: SshHandle): StableNodeIdentity {
		val result = checked(handle, "bash $REMOTE_ROOT/linux/23-node-identity.sh --show", emit = false)
		return ProtocolParsers.stableNodeIdentity(result.stdout, handle.target.id)
	}

    private suspend fun syncStableNodeIdentity(handle: SshHandle) {
		stableNodes.put(readStableNodeIdentity(handle))
	}

	private suspend fun ensureInstallNodeIdentity(handle: SshHandle, original: ToolkitProbe) {
		runCatching { readStableNodeIdentity(handle) }.getOrNull()?.let {
			stableNodes.put(it)
			return
		}
		val sameVersion = original.installed && runCatching { ProtocolParsers.compareVersions(original.version, VERSION) == 0 }.getOrDefault(false)
		var legacyBootstrap = false
		if (sameVersion) {
			val legacyProbe = original.brand == "PNA_LEGACY" && original.root == LEGACY_REMOTE_ROOT && !original.complete
			val interruptedMigration = original.brand == "TNA" && original.root == REMOTE_ROOT
			check(legacyProbe || interruptedMigration) { tr("同版本节点缺失稳定身份；拒绝用新身份掩盖漂移", "Same-version node is missing stable identity; refusing to hide drift with a new identity") }
			val evidence = checked(handle, """
				set -eu
				journal=/var/lib/text-node-assistant/migrations/pna-to-tna-v1.env
				state=/var/lib/text-node-assistant/migrations/legacy-identity-bootstrap-v1.env
				[ -f "${'$'}journal" ] && [ ! -L "${'$'}journal" ]
				grep -Fqx MIGRATION_STATUS=COMMITTED "${'$'}journal"
				grep -Eq '^MIGRATION_COPIED=(ETC_STATE|ROOT_STATE)${'$'}' "${'$'}journal"
				legacy=${'$'}(readlink -f $LEGACY_REMOTE_ROOT)
				[ -n "${'$'}legacy" ] && [ "${'$'}legacy" != $REMOTE_ROOT ]
				[ -s "${'$'}legacy/TOOLKIT_VERSION" ] && [ ! -x "${'$'}legacy/linux/23-node-identity.sh" ]
				[ ! -L "${'$'}state" ]
				! grep -Fqx IDENTITY_BOOTSTRAP_STATUS=COMMITTED "${'$'}state" 2>/dev/null
				if [ ! -s "${'$'}state" ]; then printf 'SCHEMA_VERSION=1\nIDENTITY_BOOTSTRAP_STATUS=IN_PROGRESS\n' > "${'$'}state.tmp.${'$'}${'$'}"; chmod 600 "${'$'}state.tmp.${'$'}${'$'}"; mv -f "${'$'}state.tmp.${'$'}${'$'}" "${'$'}state"; fi
				grep -Fqx IDENTITY_BOOTSTRAP_STATUS=IN_PROGRESS "${'$'}state"
				printf 'TNA_LEGACY_IDENTITY_BOOTSTRAP_EVIDENCE_OK\n'
			""".trimIndent(), emit = false)
			check("TNA_LEGACY_IDENTITY_BOOTSTRAP_EVIDENCE_OK" in evidence.stdout) { "legacy identity evidence marker missing" }
			legacyBootstrap = true
		}
		val initialized = checked(handle, "bash $REMOTE_ROOT/linux/23-node-identity.sh --init", emit = false)
		val identity = ProtocolParsers.stableNodeIdentity(initialized.stdout, handle.target.id)
		if (legacyBootstrap) {
			val committed = checked(handle, "set -eu; state=/var/lib/text-node-assistant/migrations/legacy-identity-bootstrap-v1.env; grep -Fqx IDENTITY_BOOTSTRAP_STATUS=IN_PROGRESS \"${'$'}state\"; sed 's/^IDENTITY_BOOTSTRAP_STATUS=.*/IDENTITY_BOOTSTRAP_STATUS=COMMITTED/' \"${'$'}state\" > \"${'$'}state.tmp.${'$'}${'$'}\"; chmod 600 \"${'$'}state.tmp.${'$'}${'$'}\"; mv -f \"${'$'}state.tmp.${'$'}${'$'}\" \"${'$'}state\"; printf 'TNA_LEGACY_IDENTITY_BOOTSTRAP_COMMITTED\\n'", emit = false)
			check("TNA_LEGACY_IDENTITY_BOOTSTRAP_COMMITTED" in committed.stdout)
		}
		stableNodes.put(identity)
	}

	private fun sameStableNode(expected: StableNodeIdentity, actual: StableNodeIdentity): Boolean =
		expected.serverId == actual.serverId && expected.nodeId == actual.nodeId &&
			expected.machineIdSha256 == actual.machineIdSha256 && expected.hostKeySha256 == actual.hostKeySha256

	private fun openCloudflareDnsDashboard(): Boolean = runCatching {
		val uri = Uri.parse(CLOUDFLARE_DNS_DASHBOARD)
		check(uri.scheme == "https" && uri.host == "dash.cloudflare.com")
		context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
	}.isSuccess

	private fun directDnsMatches(domain: String, ip: String): Boolean = runCatching {
		val ipv4 = InetAddress.getAllByName(domain).mapNotNull { (it as? Inet4Address)?.hostAddress }.distinct()
		ipv4.isNotEmpty() && ipv4.all { it == ip }
	}.getOrDefault(false)

	private suspend fun rebindPublicIp(oldTarget: NodeTarget): SshHandle? {
		val expected = stableNodes.get(oldTarget.id) ?: error(tr(
			"LOCAL_KEY_RECORD_NOT_FOUND：旧节点尚无稳定 NODE_ID/SERVER_ID。若旧地址仍可用，先用长期 key 成功执行任一远端操作完成迁移；不会自动生成新 key。",
			"LOCAL_KEY_RECORD_NOT_FOUND: the old target has no stable NODE_ID/SERVER_ID. If it still works, complete any remote action with its managed key first. No new key is generated.",
		))
		check(managedKeys.get(oldTarget.id) != null && hostKeys.get(oldTarget.id) != null) { "LOCAL_KEY_RECORD_NOT_FOUND" }
		val newIp = required(tr("新公网 IPv4", "New public IPv4"), tr("输入服务商已经分配给同一 VPS 的新公网 IPv4", "Enter the new public IPv4 already assigned to the same VPS")) { ProtocolParsers.validCanonicalPublicIpv4(it) }
		check(newIp != expected.currentPublicIp) { tr("新 IP 与旧 IP 相同，没有重绑定动作可做", "The new IP equals the old IP; there is nothing to rebind") }
		val newPort = required(tr("新 SSH 端口", "New SSH port"), tr("默认沿用旧端口；可输入新端口", "Keep the old port by default, or enter a new port"), oldTarget.port.toString()) { value -> value.toIntOrNull()?.let { it in 1..65535 } == true }.toInt()
		val newTarget = NodeTarget(newIp, oldTarget.user, newPort, oldTarget.label)
		var session = runCatching { ssh.connectRebound(oldTarget, newTarget, null, language) }.getOrElse { first ->
			check(first.message?.contains("PUBLICKEY_REJECTED") == true) { throw first }
			val password = prompts.ask(
				tr("当前 VPS 密码", "Current VPS password"),
				tr("PUBLICKEY_REJECTED：服务器 Host Key 已匹配。密码只用于本次认证并重新安装同一公钥，不会保存或生成新 key。", "PUBLICKEY_REJECTED: the server host key matched. The password is used only for this authentication and reinstalling the same public key; it is not saved and no key is generated."),
				PromptKind.SECRET,
			)
			ssh.connectRebound(oldTarget, newTarget, password, language)
		}
		var handle = session.handle
		try {
			if (session.usedPasswordFallback) {
				val originalKey = requireNotNull(managedKeys.get(oldTarget.id))
				installPublicKey(handle, originalKey.publicKeyOpenSsh)
			}
			val actual = readStableNodeIdentity(handle)
			check(sameStableNode(expected, actual) && actual.currentPublicIp == expected.currentPublicIp) { "IP_REBIND_BLOCKED_PRE_DNS: NODE_ID/SERVER_ID/machine-id/host-key mismatch" }
			val exactProbe = probe(handle)
			check(exactProbe.installed && exactProbe.complete && exactProbe.version == VERSION && exactProbe.buildId == BUILD_ID && exactProbe.buildRevision == BUILD_REVISION) { "IP_REBIND_BLOCKED_PRE_DNS: toolkit build mismatch" }
			val publicEnv = ProtocolParsers.kv(checked(handle, "if [ -r /etc/text-node-assistant/public.env ]; then cat /etc/text-node-assistant/public.env; else cat /etc/proxy-runbook/public.env; fi", emit = false).stdout)
			val oldDomain = publicEnv["COVER_DOMAIN"].orEmpty().lowercase()
			check(Validation.validDomain(oldDomain)) { "IP_REBIND_BLOCKED_PRE_DNS: invalid managed construction domain" }
			val newDomain = required(tr("新施工域名", "New construction domain"), tr("直接确认表示保留原域名；更换域名会停在 Cloudflare 人工阶段", "Keep the default to retain the domain; a changed domain stops at the Cloudflare manual phase"), oldDomain) { Validation.validDomain(it) }.lowercase()
			val arguments = listOf(expected.currentPublicIp, newIp, oldDomain, newDomain).joinToString(" ") { SshHandle.shellQuote(it) }
			val preflight = checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh preflight $arguments", emit = false)
			val values = ProtocolParsers.kv(markedCurrentOrLegacy(preflight.stdout, "__TNA_IP_REBIND_PREFLIGHT_V1_BEGIN__", "__TNA_IP_REBIND_PREFLIGHT_V1_END__", "__PNA_IP_REBIND_PREFLIGHT_V1_BEGIN__", "__PNA_IP_REBIND_PREFLIGHT_V1_END__"))
			check(values["IP_REBIND_STATUS"] == "IP_REBIND_PREPARED" && values["SERVER_ID_MATCH"] == "1" && values["NODE_ID_UNCHANGED"] == "1" && values["MACHINE_ID_MATCH"] == "1" && values["REMOTE_PUBLIC_IP_MATCH"] == "1" && values["DNS_MUTATED"] == "0" && values["CLOUDFLARE_MUTATION"] == "NONE") { "IP_REBIND_BLOCKED_PRE_DNS: invalid preflight protocol" }
			log(preflight.stdout.trim())
			val direct = (values["DEPLOYMENT_MODE"] == "direct-reality" && values["ACTIVE_MODE"] == "ACTIVE_DIRECT") ||
				(values["DEPLOYMENT_MODE"] == "dual-hot-switch" && values["ACTIVE_MODE"] == "DUAL_INSTALLED_ACTIVE_DIRECT")
			if (!direct || newDomain != oldDomain) {
				val wait = checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh wait-cloudflare $arguments", emit = false)
				check(wait.stdout.contains("IP_REBIND_STATUS=WAITING_FOR_CLOUDFLARE_MANUAL_ACTION"))
				log("CLOUDFLARE_DASHBOARD_OPENED=${openCloudflareDnsDashboard()}")
				val parked = tr("事务已安全停在 Cloudflare 人工确认阶段；橙云不得关闭，本地 key endpoint 尚未提交。", "The transaction is safely parked for manual Cloudflare validation. Orange-cloud proxying must remain enabled; the local key endpoint is not committed.")
				log(parked)
				handle.close()
				throw ParkedWorkflow(parked)
			}
			log("CLOUDFLARE_DASHBOARD_OPENED=${openCloudflareDnsDashboard()}")
			while (!directDnsMatches(newDomain, newIp)) {
				val answer = prompts.ask(tr("等待 DNS", "Waiting for DNS"), tr("把 A 记录改为新 IP 并保持 DNS only。按确认重新检测，输入 q 在 DNS 前安全停止。", "Update the A record to the new IP and keep DNS only. Confirm to re-check, or enter q to stop safely before DNS."), PromptKind.TEXT)
				if (answer.equals("q", true)) {
					runCatching { checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh abort-pre-dns", emit = false) }
					handle.close()
					throw CancellationException("IP_REBIND_ABORTED_PRE_DNS")
				}
			}
			val commit = checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh commit-direct $arguments", emit = false)
			check(commit.stdout.contains("IP_REBIND_STATUS=IP_REBIND_COMPLETE")) { "IP_REBIND_BLOCKED_POST_DNS" }
			val committedIdentity = readStableNodeIdentity(handle)
			check(sameStableNode(expected, committedIdentity) && committedIdentity.currentPublicIp == newIp) { "IP_REBIND_BLOCKED_POST_DNS: identity readback failed" }
			check(managedKeys.rebind(oldTarget.id, newTarget.id)) { "IP_REBIND_BLOCKED_POST_DNS: local managed-key endpoint commit failed" }
			hostKeys.commitRebind(oldTarget.id, session.presentedHostKey)
			stableNodes.rebind(oldTarget.id, committedIdentity)
			targets.remember(newTarget)
			log(commit.stdout.trim())
			log("SSH_AUTH_KEY_ID_UNCHANGED=1")
			showHandoff(handle)
			return handle
		} catch (error: Throwable) {
			handle.close()
			throw error
		}
	}

    private suspend fun showHandoff(handle: SshHandle, additionalSecretHandoff: String = "") {
        val command = "printf '%s\\n' '${ProtocolParsers.HANDOFF_BEGIN}'; if [ -r /root/.config/text-node-assistant/HANDOFF-SECRETS.txt ]; then cat /root/.config/text-node-assistant/HANDOFF-SECRETS.txt; else cat /root/.config/proxy-runbook/HANDOFF-SECRETS.txt 2>/dev/null || true; fi; printf '%s\\n' '${ProtocolParsers.HANDOFF_END}'"
        val result = checked(handle, command, emit = false)
        val legacy = ProtocolParsers.handoff(result.stdout)
        val login = ProtocolParsers.loginCredentialForm(legacy)
        val fields = linkedMapOf(
            "TNA_VERSION" to VERSION,
            "VPS_SSH_USER" to handle.target.user,
            "VPS_SSH_PORT" to handle.target.port.toString(),
            "VPS_PASSWORD_STATUS" to "PRESENT_IN_PROTECTED_HANDOFF",
            "SSH_AUTH_MODE" to if (managedKeys.get(handle.target.id) != null) "MANAGED_KEY" else "TEMPORARY_PASSWORD_ONE_RUN",
            "SSH_KEY_ONLY" to (managedKeys.get(handle.target.id) != null).toString(),
            "CURRENT_DEVICE_ID" to deviceIdentity.loadOrCreate().deviceId,
            "CURRENT_ORIGIN_CONCEALED" to "false",
            "FORM_VPS_ACCOUNT" to login.getValue("FORM_VPS_ACCOUNT"),
            "FORM_VPS_PASSWORD" to login.getValue("FORM_VPS_PASSWORD"),
            "FORM_PANEL_ACCOUNT" to login.getValue("FORM_PANEL_ACCOUNT"),
            "FORM_PANEL_PASSWORD" to login.getValue("FORM_PANEL_PASSWORD"),
        )
        managedKeys.get(handle.target.id)?.let { record ->
            fields["SSH_PRIVATE_KEY_STORAGE"] = "ANDROID_KEYSTORE_ENCRYPTED_APP_PRIVATE"
            fields["SSH_AUTH_KEY_ID"] = sshAuthenticationKeyId(record.publicKeyOpenSsh)
        }
        runCatching { ProtocolParsers.kv(checked(handle, "if [ -r /etc/text-node-assistant/public.env ]; then cat /etc/text-node-assistant/public.env; else cat /etc/proxy-runbook/public.env 2>/dev/null || true; fi", emit = false).stdout) }.getOrNull()?.let { runtime ->
            runtime["PUBLIC_IP"]?.takeIf(ProtocolParsers::validCanonicalPublicIpv4)?.let { fields["VPS_PUBLIC_IP"] = it }
            runtime["COVER_DOMAIN"]?.takeIf(Validation::validDomain)?.let { fields["CONSTRUCTION_DOMAIN"] = it.lowercase() }
        }
        runCatching { ProtocolParsers.kv(checked(handle, "if [ -r /etc/text-node-assistant/deployment-state.env ]; then cat /etc/text-node-assistant/deployment-state.env; else cat /etc/proxy-runbook/deployment-state.env 2>/dev/null || true; fi", emit = false).stdout) }.getOrNull()?.let { deployment ->
            fields["DEPLOYMENT_MODE"] = deployment["DEPLOYMENT_MODE"].orEmpty().ifBlank { "direct-reality" }
            fields["ACTIVE_MODE"] = deployment["ACTIVE_MODE"].orEmpty().ifBlank { "ACTIVE_DIRECT" }
            fields["ORIGIN_HISTORY"] = deployment["ORIGIN_HISTORY"].orEmpty().ifBlank { "unknown" }
            fields["V095_CDN_STATUS"] = if (fields["DEPLOYMENT_MODE"] == "direct-reality") "NOT_CONFIGURED" else fields["ACTIVE_MODE"].orEmpty()
            fields["V095_PHASE_STATUS"] = if (fields["DEPLOYMENT_MODE"] == "direct-reality") "DIRECT_COMPATIBILITY_BASELINE" else "EXPERIMENTAL_STAGED_NOT_PUBLICLY_PROMOTED"
        }
        runCatching { readStableNodeIdentity(handle) }.getOrNull()?.let { identity ->
            fields["SERVER_ID"] = identity.serverId
            fields["NODE_ID"] = identity.nodeId
            fields["MACHINE_ID_SHA256"] = identity.machineIdSha256
            fields["SSH_HOST_KEY_SHA256"] = identity.hostKeySha256
            fields["FIRST_KNOWN_PUBLIC_IP"] = identity.firstKnownPublicIp
            fields["CURRENT_PUBLIC_IP"] = identity.currentPublicIp
        }
        runCatching { ProtocolParsers.panel(checked(handle, "bash $REMOTE_ROOT/linux/18-panel-metadata.sh", emit = false).stdout) }.getOrNull()?.let { panel ->
            fields["PANEL_REMOTE_LOOPBACK_PORT"] = panel.port.toString()
            fields["PANEL_LOCAL_URL_TEMPLATE"] = "http://127.0.0.1:<LOCAL_TUNNEL_PORT>${panel.path}"
            fields["PANEL_SSH_TUNNEL_INSTRUCTION"] = "Use Android operation 2; the application creates a localhost SSH tunnel."
            fields["FORM_PANEL_LOCAL_URL"] = "http://127.0.0.1:<LOCAL_TUNNEL_PORT>${panel.path}"
        }
        runCatching { ProtocolParsers.kv(checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh status 2>/dev/null || true", emit = false).stdout) }.getOrNull()?.let { drive ->
            if (drive["PRIVATE_DRIVE_MODE"] == "copyparty") {
                fields["PRIVATE_DRIVE_MODE"] = "copyparty"
                fields["PRIVATE_DRIVE_STATUS"] = drive["PRIVATE_DRIVE_STATUS"].orEmpty()
                fields["MANDATORY_DRIVE_ACCESS"] = "LOCAL_SSH_TUNNEL_ONLY"
                fields["PRIVATE_DRIVE_PUBLIC_ACCESS"] = "NOT_USED"
                fields["DRIVE_DOMAIN_REQUIRED"] = "false"
                fields["DRIVE_REGISTRATION_READY"] = drive["DRIVE_REGISTRATION_READY"].orEmpty().ifBlank { "unknown" }
            } else {
                fields["PRIVATE_DRIVE_MODE"] = "disabled"
            }
        }
        val handoff = ProtocolParsers.completeHandoff(legacy, fields) + additionalSecretHandoff.takeIf { it.isNotBlank() }?.let { "\n\n$it" }.orEmpty()
        _state.update { it.copy(secretHandoff = handoff) }
        log("CREDENTIAL_HANDOFF_VALIDATED; secrets are shown only in the protected handoff panel")
    }

    private fun sshAuthenticationKeyId(publicKey: String): String {
        val fields = publicKey.trim().split(Regex("\\s+"))
        require(fields.size >= 2 && fields[0] == "ssh-ed25519") { "unsupported managed SSH public key" }
        val blob = Base64.decode(fields[1], Base64.DEFAULT)
        require(blob.size >= 32) { "invalid managed SSH public key" }
        return "SHA256:" + Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(blob), Base64.NO_WRAP or Base64.NO_PADDING)
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

    private suspend fun privateDrive(handle: SshHandle): Boolean {
        val choice = prompts.ask(
            tr("强制网盘控制中心", "Mandatory drive control center"),
            tr(
                "网盘是受管基线的一部分，只允许本机 SSH 隧道访问；只有菜单 [1] 可安装。\n[1] 脱敏状态  [2] 打开网盘  [3] 轮换 admin 能力  [4] 列出普通账号  [5] 注册普通账号（每 VPS 最多 2 个）  [0] 返回",
                "The drive is part of the managed baseline and is reachable only through a local SSH tunnel; only action 1 installs it.\n[1] Redacted status  [2] Open drive  [3] Rotate admin capability  [4] List ordinary accounts  [5] Register ordinary account (maximum 2 per VPS)  [0] Back",
            ),
            PromptKind.TEXT,
            defaultValue = "1",
        ).trim().ifEmpty { "1" }
        return when (choice) {
            "1" -> { checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh status"); false }
            "2" -> openDriveTunnel(handle)
            "3" -> { rotateDriveAdminCapability(handle); false }
            "4" -> { checked(handle, "bash $REMOTE_ROOT/linux/30-copyparty-account.sh list"); false }
            "5" -> { registerOrdinaryDriveAccount(handle); false }
            "0" -> false
            else -> error(tr("强制网盘选项无效", "Invalid mandatory-drive selection"))
        }
    }

    private suspend fun rotateDriveAdminCapability(handle: SshHandle) {
        val identityStatus = DeviceAdmissionProtocol.parseStatus(checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh status", emit = false).stdout)
        val identity = deviceIdentity.loadOrCreate()
        require(identityStatus.devices.any { it.deviceId == identity.deviceId && it.role == "controller" && it.status == "active" }) {
            tr("只有此节点的 active controller 能轮换 admin 能力", "Only an active controller for this node can rotate the admin capability")
        }
        val username = randomDriveAdminUsername()
        val password = randomDrivePassword()
        val current = driveStatus(handle)
        val quota = current["PRIVATE_DRIVE_QUOTA_GIB"].orEmpty().takeIf { it.toIntOrNull() != null } ?: "auto"
        val result = handle.exec(
            "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh rotate-admin ${SshHandle.shellQuote(username)} ${SshHandle.shellQuote(quota)}",
            root = true,
            stdinBytes = "$password\n".toByteArray(),
            log = ::log,
        )
        check(result.ok && "__TNA_DRIVE_RESULT_END__" in result.stdout)
        verifyDriveAdmin(handle, username, password)
        driveAdminCapabilities.put(DriveAdminCapability(identityStatus.nodeId, username, password))
        _state.update { it.copy(secretHandoff = "===== TNA DRIVE ADMIN ROTATION v0.9.5 =====\nDRIVE_ADMIN_USERNAME=$username\nDRIVE_ADMIN_PASSWORD=$password\nSTORAGE=ANDROID_KEYSTORE_ENCRYPTED_APP_VAULT") }
    }

    private suspend fun registerOrdinaryDriveAccount(handle: SshHandle) {
        val identity = deviceIdentity.loadOrCreate()
        val status = DeviceAdmissionProtocol.parseStatus(checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh status", emit = false).stdout)
        require(status.devices.any { it.deviceId == identity.deviceId && it.role == "controller" && it.status == "active" }) {
            tr("只有 active controller 能注册普通网盘账号", "Only an active controller can register an ordinary drive account")
        }
        val username = required(tr("普通网盘用户名", "Ordinary drive username"), tr("3—32 位；不能使用 admin/root", "3-32 characters; admin/root are reserved")) {
            Regex("^[A-Za-z][A-Za-z0-9._-]{2,31}$").matches(it) && it.lowercase() !in setOf("admin", "root") && !it.startsWith("tna-admin-")
        }
        val password = randomDrivePassword()
        val quota = required(tr("账号容量", "Account quota"), tr("推荐 auto；也可输入 1—50 GiB", "Recommended: auto; or enter 1-50 GiB"), "auto") {
            it == "auto" || it.toIntOrNull()?.let { number -> number in 1..50 } == true
        }
        val random = SecureRandom()
        val accountId = "tna-account-" + ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val spaceId = "tna-space-" + ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val controllersResult = checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh controller-encryption-keys ${SshHandle.shellQuote(identity.deviceId)}", emit = false)
        val block = markedCurrentOrLegacy(
            controllersResult.stdout,
            "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_BEGIN__",
            "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_END__",
            "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_BEGIN__",
            "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_END__",
        )
        val controllers = block.lines().filter { it.isNotBlank() }.map { row ->
            val parts = row.split('\t')
            require(parts.size == 3 && parts[0] == "CONTROLLER")
            ControllerEncryptionKey(parts[1], parts[2])
        }
        val escrow = DriveEscrowCodec.encryptNew(status.nodeId, accountId, spaceId, username, password, controllers, deviceIdentity)
        val encodedEscrow = DriveEscrowCodec.rawUrl(DriveEscrowCodec.encode(escrow).toByteArray())
        val result = handle.exec(
            "bash $REMOTE_ROOT/linux/30-copyparty-account.sh register ${SshHandle.shellQuote(username)} ${SshHandle.shellQuote(quota)} ${SshHandle.shellQuote(accountId)} ${SshHandle.shellQuote(spaceId)}",
            root = true,
            stdinBytes = "$password\n$encodedEscrow\n".toByteArray(),
            log = ::log,
        )
        check(result.ok && "__TNA_DRIVE_ACCOUNT_RESULT_END__" in result.stdout) { "Drive account registration failed (${result.exitCode})" }
        _state.update { it.copy(secretHandoff = "===== TNA ORDINARY DRIVE ACCOUNT v0.9.5 =====\nDRIVE_ACCOUNT_ID=$accountId\nDRIVE_SPACE_ID=$spaceId\nDRIVE_USERNAME=$username\nDRIVE_PASSWORD=$password\nACCESS=ALL_TRUSTED_DEVICES_AFTER_LOGIN") }
    }

    private suspend fun cdnPublicIp(handle: SshHandle): String {
        val result = checked(handle, "ip=\$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); [ -n \"\$ip\" ] || ip=\$(hostname -I | awk '{print \$1}'); printf '%s\\n' \"\$ip\"", emit = false)
        return result.stdout.lines().map { it.trim() }.firstOrNull { runCatching { InetAddress.getByName(it) is Inet4Address }.getOrDefault(false) }
            ?: error(tr("无法确定 VPS 公网 IPv4", "Could not determine the VPS public IPv4"))
    }

    private fun verifyDirectOriginBlocked(publicIp: String) {
        val reachable = runCatching {
            Socket().use { socket -> socket.connect(InetSocketAddress(publicIp, 8443), 5_000) }
        }.isSuccess
        check(!reachable) { tr("外部设备仍能直连源站 8443，拒绝宣称已锁源", "This external device can still reach origin 8443; origin lock cannot be claimed") }
    }

    private fun verifyCloudflareEdge(domain: String) {
        val connection = URL("https://$domain:8443/").openConnection(Proxy.NO_PROXY) as HttpsURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 30_000
        connection.instanceFollowRedirects = true
        connection.requestMethod = "GET"
        try {
            val status = connection.responseCode
            check(status in 200..399) { "Cloudflare edge returned HTTP $status" }
            check(!connection.getHeaderField("Cf-Ray").isNullOrBlank()) { "Cloudflare edge response is missing Cf-Ray" }
            check(connection.getHeaderField("X-TNA-Managed-Origin") == "cdn-xhttp-v095") { "managed 8443 origin marker is missing" }
            check(connection.getHeaderField("X-TNA-Origin-Port") == "8443") { "managed 8443 edge route was not proven" }
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun cdnXhttpControl(handle: SshHandle) {
        val choice = prompts.ask(
            tr("链路拓扑状态", "Link-topology status"),
            tr(
                "拓扑施工、切换和拆除只允许通过操作 [1]，这里不会改 DNS、Cloudflare、防火墙或节点。\n[1] 查看脱敏拓扑状态  [2] 显示并复制当前设备节点  [0] 返回",
                "Topology construction, switching, and removal are allowed only through action [1]. This screen never changes DNS, Cloudflare, the firewall, or the node.\n[1] Show redacted topology status  [2] Show and copy this device's node  [0] Back",
            ),
            PromptKind.TEXT,
            defaultValue = "1",
        ).trim().ifEmpty { "1" }
        when (choice) {
            "1" -> checked(
                handle,
                ". $REMOTE_ROOT/linux/lib-deployment-state.sh; tna_state_init_direct_if_missing; tna_state_show; " +
                    "if [ -r /etc/text-node-assistant/topology.env ]; then " +
                    "sed -n -E '/^(TOPOLOGY_MODE|GRAY_DOMAIN|ORANGE_DOMAIN|GRAY_DNS_VALIDATED|ORANGE_EDGE_VALIDATED|ACTIVE_MODE)=/p' /etc/text-node-assistant/topology.env; " +
                    "fi; bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh status 2>/dev/null || true; " +
                    "echo TOPOLOGY_MUTATION=NONE; echo TOPOLOGY_CHANGE_ENTRY=ACTION_1",
            )
            "2" -> {
                val identity = deviceIdentity.loadOrCreate()
                val result = checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh handoff ${SshHandle.shellQuote(identity.deviceId)}", emit = false)
                val block = markedCurrentOrLegacy(
                    result.stdout,
                    "__TNA_DEVICE_HANDOFF_V1_BEGIN__",
                    "__TNA_DEVICE_HANDOFF_V1_END__",
                    "__PNA_DEVICE_HANDOFF_V1_BEGIN__",
                    "__PNA_DEVICE_HANDOFF_V1_END__",
                )
                require("DIRECT_REALITY_LINK=vless://" in block || "CDN_XHTTP_LINK=vless://" in block) { "Device handoff protocol validation failed" }
                _state.update { it.copy(secretHandoff = block) }
            }
            "0" -> Unit
            else -> error(tr("链路拓扑选项无效", "Invalid link-topology selection"))
        }
    }

    private suspend fun openDriveTunnel(handle: SshHandle): Boolean {
        val status = checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh status", emit = false)
        val values = ProtocolParsers.kv(status.stdout)
        require(values["COPYPARTY_SERVICE"] == "active" && values["COPYPARTY_LOOPBACK_LISTENER"] == "1") { tr("copyparty 本地回源未就绪", "The copyparty loopback origin is not ready") }
        val remotePort = values["COPYPARTY_LOOPBACK_PORT"]?.toIntOrNull()
        require(remotePort != null && remotePort in 39000..39999) { tr("远端网盘回环端口元数据无效", "The remote drive loopback-port metadata is invalid") }
        val forward = handle.openLocalForward(remotePort)
        val url = "http://127.0.0.1:${forward.localPort}/"
        TunnelRegistry.install(context, handle, forward, url)
        activeHandle = null
        _state.update { it.copy(panelUrl = url) }
        log("PRIVATE_DRIVE_TUNNEL_ACTIVE url=$url remote=127.0.0.1:$remotePort")
        return true
    }

    private suspend fun rotateVpsPassword(handle: SshHandle) {
        val user = required(tr("VPS 用户", "VPS user"), tr("需要轮换登录密码的账户", "Account whose login password will be rotated"), handle.target.user) { Validation.validUser(it) }
        confirmYes(tr("为 $user 生成并立即应用高强度随机密码？", "Generate and immediately apply a high-entropy password for $user?"), false)
        checked(handle, "source $REMOTE_ROOT/linux/lib-handoff.sh; handoff_begin_run; bash $REMOTE_ROOT/linux/01a-rotate-vps-password.sh ${SshHandle.shellQuote(user)}")
        showHandoff(handle)
    }

    private suspend fun rotatePanelCredentials(handle: SshHandle) {
        confirmYes(tr("轮换 3x-ui 用户名和密码？现有会话会退出，2FA 可能被关闭。", "Rotate the 3x-ui username/password? Existing sessions will be logged out and 2FA may be disabled."), false)
        checked(handle, "source $REMOTE_ROOT/linux/lib-handoff.sh; handoff_begin_run; bash $REMOTE_ROOT/linux/03c-rotate-panel-credentials.sh")
        showHandoff(handle)
    }

    private suspend fun optimizeCover(handle: SshHandle) {
        val env = ProtocolParsers.kv(checked(handle, "if [ -r /etc/text-node-assistant/public.env ]; then cat /etc/text-node-assistant/public.env; else cat /etc/proxy-runbook/public.env; fi", emit = false).stdout)
        val domain = env["COVER_DOMAIN"].orEmpty()
        require(Validation.validDomain(domain)) { tr("没有有效的运行时伪装域名，请先执行操作 [1]", "No valid runtime cover domain; run action 1 first") }
        log(checked(handle, "bash $REMOTE_ROOT/linux/05b-cover-site-polished.sh --list", emit = false).stdout.trim())
        val template = required(tr("伪装站模板", "Cover template"), tr("R=随机，A=稳定选择，1—15=指定编号", "R=random, A=stable, 1-15=exact"), "R") { Validation.normalizeTemplate(it) != null }
        val selected = requireNotNull(Validation.normalizeTemplate(template))
        checked(handle, "bash $REMOTE_ROOT/linux/05b-cover-site-polished.sh ${SshHandle.shellQuote(domain)} auto ${SshHandle.shellQuote(selected)}; bash $REMOTE_ROOT/linux/05c-optimize-cover-backend.sh ${SshHandle.shellQuote(domain)}", interactive = true)
    }

    private suspend fun emergencyReport(handle: SshHandle) {
        val result = checked(handle, "bash $REMOTE_ROOT/linux/10-emergency-network-dump.sh")
        val remote = Regex("/root/emergency-network-[0-9]{8}-[0-9]{6}\\.txt").find(result.stdout)?.value ?: error(tr("无法识别诊断报告路径", "report path was not recognized"))
        val data = handle.downloadBytes(remote)
        val directory = File(context.filesDir, "reports").apply { mkdirs() }
        val file = File(directory, remote.substringAfterLast('/'))
        file.writeBytes(data)
        _state.update { it.copy(downloadedFile = file.absolutePath) }
        log("REPORT_DOWNLOADED_TO_APP_PRIVATE_STORAGE ${file.name}")
    }

    private suspend fun rotateManagedKey(handle: SshHandle) {
        val old = managedKeys.get(handle.target.id) ?: error(tr("没有已绑定的节点密钥；请先选择长期密钥登录并完成一次绑定", "No bound managed key exists; choose managed-key login once to bind one"))
        confirmYes(tr("先生成并验证新的 Ed25519 密钥，成功后再移除旧公钥？", "Generate and verify a new Ed25519 key before removing the old public key?"), false)
        val replacement = managedKeys.generate(handle.target.id)
        installPublicKey(handle, replacement.publicKeyOpenSsh)
        managedKeys.archive(handle.target.id)
        managedKeys.put(replacement)
        try {
            ssh.connect(handle.target, SessionCredential(AuthMode.MANAGED_KEY), language).use { verified ->
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
        val confirmation = required(tr("卸载远端工具包", "Uninstall toolkit"), tr("请输入大写 UNINSTALL。节点服务、配置、凭据和备份都会保留。", "Type uppercase UNINSTALL. Node services, configs, credentials, and backups are preserved.")) { it == "UNINSTALL" }
        check(confirmation == "UNINSTALL")
        val command = """
            set -Eeuo pipefail
            dirs=(/opt/text-node-assistant-v0.9.5 /opt/proxy-runbook-v0.5 /opt/proxy-runbook-v0.6 /opt/proxy-runbook-v0.6.1 /opt/proxy-runbook-v0.6.2 /opt/proxy-runbook-v0.6.5 /opt/proxy-runbook-v0.6.6 /opt/proxy-runbook-v0.7.1 /opt/proxy-runbook-v0.7.4 /opt/proxy-runbook-v0.8.2 /opt/proxy-runbook-v0.8.4 /opt/proxy-runbook-v0.8.5 /opt/proxy-runbook-v0.8.6 /opt/proxy-runbook-v0.9.0 /opt/proxy-runbook-v0.9.5)
            for target in "${'$'}{dirs[@]}"; do [ ! -e "${'$'}target" ] || { [ -d "${'$'}target" ] && [ ! -L "${'$'}target" ]; } || exit 61; done
            [ ! -e /opt/text-node-assistant-current ] || [ -L /opt/text-node-assistant-current ] || exit 62
            [ ! -e /opt/proxy-runbook-current ] || [ -L /opt/proxy-runbook-current ] || exit 62
            printf 'TNA_TOOLKIT_UNINSTALL_BEGIN\n'
            rm -f /opt/text-node-assistant-current /opt/proxy-runbook-current /usr/local/sbin/text-node /usr/local/sbin/proxy-node /tmp/text-node-assistant-toolkit-v*.tar.gz /tmp/proxy-runbook-toolkit-v*.tar.gz
            for target in "${'$'}{dirs[@]}"; do [ ! -d "${'$'}target" ] || rm -rf -- "${'$'}target"; done
            printf 'PRESERVED=NODE_SERVICES_AND_CONFIG\nTNA_TOOLKIT_UNINSTALL_END\n'
        """.trimIndent()
        val result = checked(handle, command)
        require("TNA_TOOLKIT_UNINSTALL_BEGIN" in result.stdout && "TNA_TOOLKIT_UNINSTALL_END" in result.stdout) { tr("远端返回缺少完整卸载标记", "complete uninstall markers were missing") }
    }

    private suspend fun pruneBackups(handle: SshHandle, exactConfirmation: Boolean = true) {
        if (exactConfirmation) required(tr("整理远端备份", "Prune backups"), tr("请输入大写 CLEAN：先生成一份已验证的当前配置备份，再删除已知的旧受管备份。", "Type uppercase CLEAN to create one verified current-config backup and remove known older managed backups.")) { it == "CLEAN" }
        val result = checked(handle, "bash $REMOTE_ROOT/linux/19-prune-backups-current-config.sh", interactive = true)
        listOf("CURRENT_CONFIG_BACKUP_OK", "OLD_REMAINING=0", "CURRENT_CONFIG_ARCHIVES=1", "MANIFEST_VERIFY_OK=1", "SERVICES_UNCHANGED=1").forEach { marker -> require(marker in result.stdout) { "cleanup marker $marker is missing" } }
    }

    private suspend fun performanceProfile(handle: SshHandle) {
        log(checked(handle, "bash $REMOTE_ROOT/linux/20-adaptive-performance.sh --detect", emit = false).stdout.trim())
        val choice = required(tr("性能档位", "Performance profile"), tr("0=只检测，1=自动，2=低配，3=标准，4=高吞吐，5=回滚", "0=detect only, 1=auto, 2=low, 3=standard, 4=high, 5=rollback"), "0") { it in setOf("0", "1", "2", "3", "4", "5") }
        val argument = mapOf("1" to "--apply auto", "2" to "--apply low", "3" to "--apply standard", "4" to "--apply high", "5" to "--rollback")[choice] ?: return
        if (choice == "5") confirmYes(tr("恢复最近一次性能配置备份？", "Restore the latest performance backup?"), false)
        checked(handle, "bash $REMOTE_ROOT/linux/20-adaptive-performance.sh $argument", interactive = true)
    }

    private suspend fun trafficEstimate(handle: SshHandle) {
        var status = checked(handle, "bash $REMOTE_ROOT/linux/21-traffic-status.sh --status")
        if ("VNSTAT_INSTALLED=1" !in status.stdout || "VNSTAT_DATABASE_READY=1" !in status.stdout) {
            if (!confirmYes(tr("vnStat 尚未就绪。是否安装并初始化这个低开销流量计数器？", "vnStat is not ready. Install/initialize this low-overhead counter?"), true, allowNo = true)) return
            checked(handle, "bash $REMOTE_ROOT/linux/21-traffic-status.sh --install", interactive = true)
            status = checked(handle, "bash $REMOTE_ROOT/linux/21-traffic-status.sh --status")
        }
        log(status.stdout.trim())
        checked(handle, "bash $REMOTE_ROOT/linux/21-traffic-status.sh --json")
        log("NOTICE: SSH/vnStat counters are estimates and do not replace provider billing data.")
    }

    private suspend fun dismantle(handle: SshHandle) {
        val status = ProtocolParsers.kv(checked(handle, "bash $REMOTE_ROOT/linux/22-dismantle-managed-node.sh --status", emit = false).stdout)
        val driveOnly = status["NODE_LIFECYCLE_STATE"] == "PROXY_REMOVED_DRIVE_RETAINED"
        val choice = required(
            tr("拆除施工和恢复基线", "Dismantle construction and restore baseline"),
            if (driveOnly) {
                tr("当前仅剩强制网盘。\n[1] 保持现状返回  [2] 拆除剩余网盘并完整恢复原生基线", "Only the mandatory drive remains.\n[1] Keep it and return  [2] Remove the remaining drive and fully restore the native baseline")
            } else {
                tr("[1] 只拆代理，保留网盘、账号、设备准入和 SSH\n[2] 整体拆除并恢复原生基线", "[1] Remove proxy only; retain drive, accounts, device admission, and SSH\n[2] Remove everything and restore the native baseline")
            },
        ) { it in setOf("1", "2") }
        if (driveOnly && choice == "1") return
        val target = if (driveOnly) "remaining-drive" else if (choice == "1") "proxy-only" else "full"
        val plan = checked(handle, "bash $REMOTE_ROOT/linux/22-dismantle-managed-node.sh --plan $target")
        require("TNA_DISMANTLE_PLAN_BEGIN" in plan.stdout && "TNA_DISMANTLE_PLAN_END" in plan.stdout) { tr("远端返回缺少完整拆除计划标记", "complete dismantle plan markers are missing") }
        if (target == "proxy-only") {
            required(tr("只拆代理", "Proxy-only removal"), tr("请输入大写 REMOVE PROXY KEEP DRIVE。任何拆除前都会先下载救援包。", "Type uppercase REMOVE PROXY KEEP DRIVE. A rescue archive is downloaded before removal.")) { it == "REMOVE PROXY KEEP DRIVE" }
        } else {
            required(tr("完整恢复原生基线", "Full native-baseline restore"), tr("请输入大写 RESTORE ORIGINAL。任何拆除前都会先下载救援包。", "Type uppercase RESTORE ORIGINAL. A rescue archive is downloaded before removal.")) { it == "RESTORE ORIGINAL" }
        }
        val legacy = "RESTORE_GRADE=LEGACY_UNCERTAIN" in plan.stdout
        if (legacy && target != "proxy-only") required(tr("旧版本限制", "Legacy limitation"), tr("请输入大写 LEGACY FULL RESTORE，确认接受在没有逐字节原始基线时执行有界拆除。", "Type uppercase LEGACY FULL RESTORE to accept bounded removal without a byte-for-byte baseline.")) { it == "LEGACY FULL RESTORE" }
        val backup = checked(handle, "bash $REMOTE_ROOT/linux/01-safe-backup.sh")
        require("BACKUP_OK" in backup.stdout) { tr("拆除前救援备份失败", "pre-dismantle backup failed") }
        val remote = Regex("/root/proxy-node-backup-[0-9]{8}-[0-9]{6}\\.tar\\.gz").find(backup.stdout)?.value ?: error(tr("远端返回缺少救援包路径", "rescue archive path missing"))
        val bytes = handle.downloadBytes(remote)
        require(bytes.size > 1024) { tr("下载的救援包异常过小", "downloaded rescue archive is unexpectedly small") }
        val directory = File(context.filesDir, "rescue").apply { mkdirs() }
        val file = File(directory, remote.substringAfterLast('/')).apply { writeBytes(bytes) }
        _state.update { it.copy(downloadedFile = file.absolutePath) }
        log("RESCUE_ARCHIVE_DOWNLOADED ${file.name}")
        val env = when {
            target == "proxy-only" -> "TNA_DISMANTLE_CONFIRM=REMOVE_PROXY_KEEP_DRIVE"
            legacy -> "TNA_DISMANTLE_CONFIRM=RESTORE_ORIGINAL TNA_LEGACY_FULL=1"
            else -> "TNA_DISMANTLE_CONFIRM=RESTORE_ORIGINAL"
        }
        val verb = if (target == "proxy-only") "--execute-proxy-only" else if (target == "remaining-drive") "--execute-remaining-drive" else "--execute-full"
        val result = checked(handle, "$env bash $REMOTE_ROOT/linux/22-dismantle-managed-node.sh $verb", interactive = true)
        listOf("TNA_DISMANTLE_BEGIN", "SSH_ACCESS_PRESERVED=1", "PRESERVED_SHARED_BASE_PACKAGES=1", "TNA_DISMANTLE_END").forEach { require(it in result.stdout) { "dismantle marker $it missing; rescue retained" } }
    }

    private suspend fun securityEvents(handle: SshHandle) {
        while (true) {
            val choice = required(
                tr("访问与封禁日志", "Access and ban events"),
                tr("1=最近24小时，2=选择范围，3=安装/修复受管 Fail2ban，4=查看基线，0=返回", "1=last 24h, 2=choose range, 3=install/repair managed Fail2ban, 4=baseline status, 0=back"),
                "1",
            ) { it in setOf("0", "1", "2", "3", "4") }
            when (choice) {
                "0" -> return
                "3" -> {
                    if (!confirmYes(tr("应用受管 sshd jail（5次/10分钟，封禁1小时）和隐私化连接元数据规则？", "Apply the managed sshd jail (5 attempts/10 minutes, 1-hour ban) and privacy-preserving connection metadata?"), false, allowNo = true)) continue
                    val applied = checked(handle, "bash $REMOTE_ROOT/linux/24-security-baseline.sh --apply 7", emit = false)
                    require("TNA_SECURITY_BASELINE_APPLIED" in applied.stdout && "TNA_SECURITY_BASELINE_STATUS_END" in applied.stdout) { tr("安全基线返回不完整", "Security-baseline response was incomplete") }
                    log(applied.stdout.trim())
                }
                "4" -> {
                    val status = checked(handle, "bash $REMOTE_ROOT/linux/24-security-baseline.sh --status", emit = false)
                    require("TNA_SECURITY_BASELINE_STATUS_BEGIN" in status.stdout && "TNA_SECURITY_BASELINE_STATUS_END" in status.stdout) { tr("安全基线状态返回不完整", "Security-baseline status was incomplete") }
                    log(status.stdout.trim())
                }
                else -> {
                    val since = if (choice == "2") required(
                        tr("时间范围", "Time range"),
                        "1h / 6h / 24h / 7d",
                        "24h",
                    ) { it in setOf("1h", "6h", "24h", "7d") } else "24h"
                    val result = checked(handle, "bash $REMOTE_ROOT/linux/25-security-events.sh --protocol-v1 --since $since --cursor 0 --limit 200", emit = false)
                    require(result.stdout.count { it == '\n' } <= 1300) { tr("安全事件响应超过边界", "Security-event response exceeded its bound") }
                    require("__TNA_SECURITY_V1_BEGIN__" in result.stdout && "__TNA_SECURITY_V1_END__" in result.stdout && "SUMMARY\t" in result.stdout) { tr("安全事件协议返回不完整", "Security-event protocol response was incomplete") }
                    log(tr("连接/失败事件不自动等同攻击；只有 Fail2ban 当前封禁具有明确封禁语义。", "Connection/failure events are not automatically attacks; only current Fail2ban bans have explicit ban semantics."))
                    log(result.stdout.trim())
                }
            }
        }
    }

    private suspend fun deviceAdmission(handle: SshHandle) {
        val identity = deviceIdentity.loadOrCreate()
        while (true) {
            val statusResult = checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh status", emit = false)
            val status = DeviceAdmissionProtocol.parseStatus(statusResult.stdout)
            log(buildString {
                appendLine("DEVICE_ADMISSION node=${status.nodeId} active_controllers=${status.activeControllers} active_devices=${status.activeDevices}")
                status.devices.forEach { appendLine("${it.deviceId} role=${it.role} status=${it.status} label=${it.label}${if (it.deviceId == identity.deviceId) " this-device" else ""}") }
                append("INVITE_POLICY=EXPIRES_AFTER_SUCCESSFUL_BIND; PER_DEVICE_VLESS=SUPPORTED")
            })
            if (status.activeControllers == 0) {
                val answer = prompts.ask(
                    tr("登记首个控制设备", "Register the first controller"),
                    tr("此节点还没有 controller。把当前 Android 设备登记为首个 controller？这会绑定本机独享 SSH key。[Y/n]", "This node has no controller. Register this Android device and bind its device-local SSH key? [Y/n]"),
                    PromptKind.YES_NO,
                    defaultValue = "y",
                ).trim().lowercase()
                if (answer in setOf("y", "yes", "是", "")) {
                    val labelValue = required(tr("设备名称", "Device label"), tr("1—64 位安全字符，例如 Android Phone", "1-64 safe characters, for example Android Phone"), "Android Phone") { Regex("^[A-Za-z0-9._ -]{1,64}$").matches(it) }
                    val existing = managedKeys.get(handle.target.id)
                    val key = existing ?: managedKeys.generate(handle.target.id)
                    val sshPublic = normalizeSshPublic(key.publicKeyOpenSsh)
                    val input = "\n${identity.publicValue}\n$labelValue\ncontroller\n${identity.encryptionPublic}\n${handle.target.user}\n$sshPublic\n\n".toByteArray()
                    val result = handle.exec("bash $REMOTE_ROOT/linux/26-device-admission.sh bootstrap-controller", root = true, stdinBytes = input, log = ::log)
                    check(result.ok && "__TNA_DEVICE_BOOTSTRAP_V1_END__" in result.stdout) { "First-controller bootstrap failed (${result.exitCode}): ${(result.stderr.ifBlank { result.stdout }).takeLast(1000)}" }
                    if (existing == null) managedKeys.put(key)
                    verifyManagedDeviceKey(handle.target)
                    log(tr("首个 controller、设备独享 SSH key 和网盘恢复公钥均已登记。", "The first controller, its device-local SSH key, and drive-recovery public key are registered."))
                    continue
                }
            }
            val choice = prompts.ask(
                tr("设备准入", "Device admission"),
                tr(
                    "[1] 刷新  [2] 显示本机公开身份  [3] 创建绑定成功后失效的邀请  [4] 指导新设备  [5] 批准响应  [6] 暂停  [7] 恢复  [8] 吊销  [9] 当前设备节点  [0] 返回",
                    "[1] Refresh  [2] Show local public identity  [3] Create bind-until-success invitation  [4] Guide new device  [5] Approve response  [6] Pause  [7] Resume  [8] Revoke  [9] Current-device nodes  [0] Back",
                ),
                PromptKind.TEXT,
                defaultValue = "1",
            ).trim().ifEmpty { "1" }
            when (choice) {
                "1" -> Unit
                "2" -> _state.update { it.copy(secretHandoff = "DEVICE_ID=${identity.deviceId}\nPUBLIC_KEY=${identity.publicValue}\nENCRYPTION_PUBLIC_KEY=${identity.encryptionPublic}\nPRIVATE_IDENTITY_STORAGE=ANDROID_KEYSTORE_ENCRYPTED_APP_VAULT") }
                "3" -> {
                    require(status.devices.any { it.deviceId == identity.deviceId && it.role == "controller" && it.status == "active" }) { tr("当前 Android 设备不是 active controller", "This Android device is not an active controller") }
                    val result = checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh create-invite ${SshHandle.shellQuote(identity.deviceId)} ${SshHandle.shellQuote(handle.target.user)}", emit = false)
                    val host = requireNotNull(hostKeys.get(handle.target.id)) { tr("本机没有已固定的 SSH Host 公钥", "No pinned SSH host key exists locally") }
                    val token = if (handle.target.port == 22) handle.target.host else "[${handle.target.host}]:${handle.target.port}"
                    val invite = DeviceAdmissionProtocol.parseInviteOutput(result.stdout, NodeEndpoint(handle.target.host, handle.target.user, handle.target.port, "$token ${host.algorithm} ${host.keyBase64}"))
                    _state.update { it.copy(secretHandoff = DeviceAdmissionProtocol.encodeInvite(invite)) }
                    log(tr("邀请只有在新设备首次 key 登录成功后才失效；批准失败或网络中断都可重试。", "The invitation is consumed only after the new device's first successful key login; approval or network failures remain retryable."))
                }
                "4" -> log(tr("在尚未获准入的新设备首页选择“新设备响应准入邀请 [J]”。该入口不要求先登录 VPS。", "On the untrusted device, choose 'Join from an untrusted device [J]' on the home screen. It requires no prior VPS login."))
                "5" -> {
                    val bundle = required(tr("粘贴新设备响应", "Paste new-device response"), "TNARESP2…") { it.startsWith("TNARESP2.") }
                    val response = DeviceAdmissionProtocol.decodeResponse(bundle)
                    require(response.nodeId == status.nodeId) { tr("响应不属于当前节点", "The response belongs to another node") }
                    val result = handle.exec("bash $REMOTE_ROOT/linux/26-device-admission.sh enroll", root = true, stdinBytes = DeviceAdmissionProtocol.enrollmentInput(response), log = ::log)
                    check(result.ok && "STATUS=pending-verification" in result.stdout && "NONCE_CONSUMED=0" in result.stdout) { "Device enrollment failed (${result.exitCode}): ${(result.stderr.ifBlank { result.stdout }).takeLast(1000)}" }
                    if (response.role == "controller") {
                        preparePendingControllerEscrow(handle, identity, response.deviceId)
                    }
                    log(tr("设备已预登记为 pending-verification；让新设备回到 [J] 按 Enter，首次 key 登录成功后才会激活并消费邀请。", "The device is pending-verification. Have it return to [J] and press Enter; only its first successful key login activates it and consumes the invitation."))
                }
                "6", "7", "8" -> {
                    val targetId = required("DEVICE_ID", "tna-device-…") { Regex("^(?:tna|pna)-device-[a-z2-7]{26}$").matches(it) }
                    val verb = mapOf("6" to "pause", "7" to "resume", "8" to "revoke").getValue(choice)
                    if (verb == "revoke") confirmYes(tr("吊销会立即删除该设备的 SSH、受管 VLESS 与网盘访问；继续？", "Revocation immediately removes this device's SSH, managed VLESS, and drive access. Continue?"), false)
                    val result = checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh $verb ${SshHandle.shellQuote(identity.deviceId)} ${SshHandle.shellQuote(targetId)}")
                    require("__TNA_DEVICE_STATE_V1_END__" in result.stdout || "__PNA_DEVICE_STATE_V1_END__" in result.stdout)
                }
                "9" -> {
                    val result = checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh handoff ${SshHandle.shellQuote(identity.deviceId)}", emit = false)
                    val block = markedCurrentOrLegacy(result.stdout, "__TNA_DEVICE_HANDOFF_V1_BEGIN__", "__TNA_DEVICE_HANDOFF_V1_END__", "__PNA_DEVICE_HANDOFF_V1_BEGIN__", "__PNA_DEVICE_HANDOFF_V1_END__")
                    require("DIRECT_REALITY_LINK=vless://" in block || "CDN_XHTTP_LINK=vless://" in block) { "Device handoff protocol validation failed" }
                    _state.update { it.copy(secretHandoff = block) }
                }
                "0" -> return
                else -> error(tr("设备准入选项无效", "Invalid device-admission selection"))
            }
        }
    }

    private data class DriveAccountRecord(
        val accountId: String,
        val spaceId: String,
        val role: String,
        val status: String,
        val username: String,
    )

    private suspend fun preparePendingControllerEscrow(
        handle: SshHandle,
        current: com.proxynodeassistant.android.data.DeviceIdentity,
        pendingDeviceId: String,
    ) {
        require(Regex("^tna-device-[a-z2-7]{26}$").matches(pendingDeviceId))
        val accountsResult = checked(handle, "bash $REMOTE_ROOT/linux/30-copyparty-account.sh list", emit = false)
        val accountBlock = markedCurrentOrLegacy(
            accountsResult.stdout,
            "__TNA_DRIVE_ACCOUNT_LIST_BEGIN__",
            "__TNA_DRIVE_ACCOUNT_LIST_END__",
            "__TNA_DRIVE_ACCOUNT_LIST_BEGIN__",
            "__TNA_DRIVE_ACCOUNT_LIST_END__",
        )
        val accounts = accountBlock.lines().filter { it.isNotBlank() }.map { line ->
            val parts = line.split('\t')
            require(parts.size == 7 && parts[0].startsWith("ACCOUNT=")) { "Invalid drive account-list row" }
            DriveAccountRecord(parts[0].removePrefix("ACCOUNT="), parts[1], parts[2], parts[3], parts[4])
        }.filter { it.role == "ordinary" && it.status in setOf("active", "paused") }
        if (accounts.isEmpty()) return

        val controllerResult = checked(
            handle,
            "bash $REMOTE_ROOT/linux/26-device-admission.sh controller-encryption-keys ${SshHandle.shellQuote(current.deviceId)} include-pending",
            emit = false,
        )
        val controllerBlock = markedCurrentOrLegacy(
            controllerResult.stdout,
            "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_BEGIN__",
            "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_END__",
            "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_BEGIN__",
            "__TNA_CONTROLLER_ENCRYPTION_KEYS_V1_END__",
        )
        val controllers = controllerBlock.lines().filter { it.isNotBlank() }.map { line ->
            val parts = line.split('\t')
            require(parts.size == 3 && parts[0] == "CONTROLLER") { "Invalid controller encryption-key row" }
            ControllerEncryptionKey(parts[1], parts[2])
        }
        require(controllers.any { it.deviceId == pendingDeviceId }) { "Pending controller encryption key was not returned by the node" }

        accounts.forEach { account ->
            val path = "/etc/text-node-assistant/drive-credential-escrow/${account.accountId}.json"
            val encoded = checked(handle, "set -eu; test -f ${SshHandle.shellQuote(path)}; base64 -w0 ${SshHandle.shellQuote(path)}", emit = false).stdout.trim()
            val raw = Base64.decode(encoded, Base64.DEFAULT).toString(Charsets.UTF_8)
            val existing = DriveEscrowCodec.decode(raw)
            require(existing.accountId == account.accountId && existing.spaceId == account.spaceId && existing.username == account.username)
            val password = DriveEscrowCodec.decrypt(existing, current, deviceIdentity)
            val rewrapped = DriveEscrowCodec.rewrap(existing, password, controllers, deviceIdentity)
            val transfer = DriveEscrowCodec.rawUrl(DriveEscrowCodec.encode(rewrapped).toByteArray()) + "\n"
            val replace = handle.exec(
                "bash $REMOTE_ROOT/linux/30-copyparty-account.sh replace-escrow ${SshHandle.shellQuote(current.deviceId)} ${SshHandle.shellQuote(account.accountId)}",
                root = true,
                stdinBytes = transfer.toByteArray(),
                log = ::log,
            )
            check(replace.ok && "TNA_DRIVE_ESCROW_REPLACED=1" in replace.stdout) {
                "Drive escrow rewrap failed for ${account.accountId}: ${(replace.stderr.ifBlank { replace.stdout }).takeLast(1000)}"
            }
            val readbackEncoded = checked(handle, "base64 -w0 ${SshHandle.shellQuote(path)}", emit = false).stdout.trim()
            val readback = DriveEscrowCodec.decode(Base64.decode(readbackEncoded, Base64.DEFAULT).toString(Charsets.UTF_8))
            check(DriveEscrowCodec.decrypt(readback, current, deviceIdentity) == password) {
                "Drive escrow authenticated readback failed for ${account.accountId}"
            }
        }
        log(tr("现有普通网盘凭据已在本机解密并重新封装给全部 active/pending controller；VPS 未收到明文密码。", "Existing ordinary-drive credentials were decrypted locally and rewrapped for all active/pending controllers; the VPS never received plaintext passwords."))
    }

    private suspend fun joinDeviceWithInvitation() {
        val bundle = required(tr("粘贴准入邀请", "Paste admission invitation"), "TNAINV2…") { it.startsWith("TNAINV2.") }
        val invite = DeviceAdmissionProtocol.decodeInvite(bundle)
        val target = NodeTarget(invite.host, invite.user, invite.port)
        importInvitationHostKey(invite, target)
        val identity = deviceIdentity.loadOrCreate()
        val labelValue = required(tr("设备名称", "Device label"), tr("1—64 位安全字符，例如 Android Phone", "1-64 safe characters, for example Android Phone"), "Android Phone") { Regex("^[A-Za-z0-9._ -]{1,64}$").matches(it) }
        val roleChoice = required(tr("设备角色", "Device role"), tr("1=仅流量/网盘（默认），2=controller", "1=traffic/drive only (default), 2=controller"), "1") { it in setOf("1", "2") }
        val role = if (roleChoice == "2") "controller" else "traffic-only"
        val existing = managedKeys.get(target.id)
        val key = existing ?: managedKeys.generate(target.id)
        val response = DeviceAdmissionProtocol.response(invite, identity, labelValue, role, key.publicKeyOpenSsh, deviceIdentity::sign)
        if (existing == null) managedKeys.put(key)
        targets.remember(target)
        _state.update { it.copy(target = target, secretHandoff = DeviceAdmissionProtocol.encodeResponse(response)) }
        log(tr("响应已生成。交给现有 controller 在设备准入 [5] 批准；批准只会预登记，不会消费邀请。", "The response is ready. Give it to an existing controller and approve it with device admission [5]. Approval only pre-registers it and does not consume the invitation."))
        prompts.ask(tr("完成首次绑定", "Complete first bind"), tr("controller 显示 pending-verification 后回到这里按 Enter。程序将用本机独享 key 首次登录；成功后邀请才失效。", "After the controller shows pending-verification, return and press Enter. The app will make the first login with its device-local key; only success consumes the invitation."), PromptKind.TEXT)
        val handle = ssh.connect(target, SessionCredential(AuthMode.MANAGED_KEY), language)
        activeHandle = handle
        try {
            val result = handle.exec("true", root = false, log = ::log)
            check(result.ok && "__TNA_DEVICE_BIND_V2_END__" in result.stdout && "NONCE_CONSUMED=1" in result.stdout) {
                tr("首次设备 key 登录尚未完成；邀请仍可重试，本机私钥已保留。", "The first device-key login is incomplete; the invitation remains retryable and the local private key is retained.")
            }
            val block = runCatching { markedCurrentOrLegacy(result.stdout, "__TNA_DEVICE_HANDOFF_V1_BEGIN__", "__TNA_DEVICE_HANDOFF_V1_END__", "__PNA_DEVICE_HANDOFF_V1_BEGIN__", "__PNA_DEVICE_HANDOFF_V1_END__") }.getOrNull()
            if (!block.isNullOrBlank()) _state.update { it.copy(secretHandoff = block) }
            log(tr("设备 SSH key、独立节点与网盘回环权限均已绑定；邀请现已失效。", "The device SSH key, independent node, and loopback-drive access are bound; the invitation is now consumed."))
        } finally {
            activeHandle = null
            handle.close()
        }
    }

    private fun importInvitationHostKey(invite: DeviceInvite, target: NodeTarget) {
        val records = invite.knownHosts.trim().lines().mapNotNull { line ->
            val parts = line.trim().split(Regex("\\s+"))
            if (parts.size < 3) null else Triple(parts[1], parts[2], runCatching { Base64.decode(parts[2], Base64.DEFAULT) }.getOrNull())
        }
        val selected = records.firstOrNull { it.first == "ssh-ed25519" } ?: records.firstOrNull() ?: error("Invitation has no usable pinned host key")
        val raw = requireNotNull(selected.third)
        hostKeys.put(HostKeyRecord(target.id, selected.first, selected.second, KeyFingerprint.createSHA256Fingerprint(raw)))
    }

    private suspend fun verifyManagedDeviceKey(target: NodeTarget) {
        val verified = ssh.connect(target, SessionCredential(AuthMode.MANAGED_KEY), language)
        try {
            val result = verified.exec("printf SSH_KEY_OK", root = false)
            check(result.ok && (result.stdout.trim() == "SSH_KEY_OK" || "__TNA_DEVICE_HANDOFF_V1_END__" in result.stdout)) { "Device SSH key did not verify" }
        } finally { verified.close() }
    }

    private fun normalizeSshPublic(value: String): String {
        val fields = value.trim().split(Regex("\\s+"))
        require(fields.size >= 2 && fields[0] == "ssh-ed25519" && fields[1].matches(Regex("^[A-Za-z0-9+/]{68}$")))
        return "${fields[0]} ${fields[1]}"
    }

    private fun markedCurrentOrLegacy(value: String, begin: String, end: String, legacyBegin: String, legacyEnd: String): String =
        runCatching { ProtocolParsers.markedBlock(value, begin, end) }.getOrElse { ProtocolParsers.markedBlock(value, legacyBegin, legacyEnd) }

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
        val answer = prompts.ask(tr("操作确认", "Confirmation"), message, PromptKind.YES_NO, defaultValue = if (defaultYes) "y" else "n").trim().lowercase()
        val yes = if (answer.isBlank()) defaultYes else answer in setOf("y", "yes", "是")
        if (!yes && !allowNo) throw CancellationException("confirmation declined")
        return yes
    }

    private suspend fun waitForDns(domain: String, publicIp: String) {
        while (true) {
            val matches = runCatching { InetAddress.getAllByName(domain).any { it.hostAddress == publicIp } }.getOrDefault(false)
            if (matches) { log("DNS_OK $domain -> $publicIp"); return }
            val answer = prompts.ask(tr("DNS 尚未就绪", "DNS not ready"), tr("请建立 A 记录：$domain → $publicIp，并使用 DNS only。按 Enter 重新检查，输入 q 取消。", "Create an A record for $domain -> $publicIp (DNS only). Press Enter to re-check or type q to cancel."), PromptKind.TEXT)
            if (answer.trim().equals("q", true)) throw CancellationException("DNS verification cancelled")
        }
    }

    private suspend fun log(line: String) {
        val safe = line.replace(Regex("(?i)(password|api[_ -]?key|token|private[_ -]?key)=\\S+"), "$1=<redacted>")
        _state.update { current -> current.copy(log = (current.log + safe).takeLast(6000), prompt = prompts.prompt.value) }
    }

    private fun safeError(error: Throwable): String {
        val safe = (error.message ?: error.javaClass.simpleName).replace(Regex("(?i)(password|api[_ -]?key|token|private[_ -]?key)=\\S+"), "$1=<redacted>")
        if (language != Language.ZH) return safe
        return when {
            safe.contains("timed out", true) -> "连接或远端命令超时：$safe"
            safe.contains("authentication", true) -> "SSH 身份认证失败：$safe"
            safe.contains("Host key", true) -> "SSH 主机公钥校验失败：$safe"
            safe.contains("Remote toolkit is missing", true) -> "远端工具包不存在，请先执行操作 [1]"
            safe.contains("Remote toolkit is incomplete", true) -> "远端工具包不完整，请先执行 [13] 卸载，再执行 [1] 安装"
            safe.contains("remote command failed", true) -> safe.replace("remote command failed", "远端命令执行失败")
            safe.startsWith("操作") || safe.startsWith("SSH") || safe.startsWith("远端") -> safe
            else -> "操作失败：$safe"
        }
    }

    private fun tr(zh: String, en: String): String = if (language == Language.ZH) zh else en

    companion object {
        const val VERSION = Product.VERSION
        const val BUILD_ID = Product.BUILD_ID
        const val BUILD_REVISION = Product.BUILD_REVISION
        const val REMOTE_ROOT = Product.REMOTE_ROOT
		const val LEGACY_REMOTE_ROOT = Product.LEGACY_REMOTE_ROOT
        const val INSTALL_ROOT = Product.INSTALL_ROOT
        const val TOOLKIT_ASSET = Product.TOOLKIT_ASSET
        const val TOOLKIT_ARCHIVE = Product.TOOLKIT_ARCHIVE
		const val CLOUDFLARE_DNS_DASHBOARD = "https://dash.cloudflare.com/?to=%2F%3Aaccount%2F%3Azone%2Fdns%2Frecords"
    }
}
