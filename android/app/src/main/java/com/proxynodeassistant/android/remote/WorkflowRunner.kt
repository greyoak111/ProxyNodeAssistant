package com.proxynodeassistant.android.remote

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import com.proxynodeassistant.android.core.PromptBroker
import com.proxynodeassistant.android.core.Validation
import com.proxynodeassistant.android.data.ManagedKeyRepository
import com.proxynodeassistant.android.data.HostKeyRepository
import com.proxynodeassistant.android.data.StableNodeIdentityRepository
import com.proxynodeassistant.android.data.DeviceIdentityRepository
import com.proxynodeassistant.android.data.TargetRepository
import com.proxynodeassistant.android.model.ActionSpec
import com.proxynodeassistant.android.model.AuthMode
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
import java.security.MessageDigest
import java.security.SecureRandom

class WorkflowRunner(
    private val context: Context,
    private val ssh: SshEngine,
    private val managedKeys: ManagedKeyRepository,
	private val hostKeys: HostKeyRepository,
	private val stableNodes: StableNodeIdentityRepository,
	private val deviceIdentity: DeviceIdentityRepository,
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
                log("PNA_ANDROID_WORKFLOW action=${action.code} target=${target.id}")
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
        "22" -> { ensureToolkit(handle); cdnXhttpPrototype(handle); false }
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
            comparison == 0 && !probe.complete -> error(tr("远端 v$VERSION 工具包不完整，请先执行 [13] 卸载，再重新安装", "Remote v$VERSION is incomplete. Explicitly uninstall with action 13 before reinstalling"))
            comparison == 0 && (probe.buildRevision > BUILD_REVISION || (probe.buildRevision == BUILD_REVISION && probe.buildId != BUILD_ID)) -> error(tr("远端 v$VERSION 构建更新或不同，已拒绝降级", "Remote v$VERSION build is newer or different; downgrade refused"))
            comparison == 0 && probe.buildRevision == BUILD_REVISION && probe.buildId == BUILD_ID -> log("TOOLKIT_SAME_BUILD; upload and bootstrap skipped")
            else -> { log("TOOLKIT_UPGRADE ${probe.version.ifBlank { "missing" }} -> $VERSION"); uploadToolkit(handle) }
        }
		syncStableNodeIdentity(handle)

        val domain = required(tr("伪装站域名", "Cover domain"), tr("请本人输入域名；没有默认值，也不会读取历史秘密", "Type the cover domain yourself (no default)")) { Validation.validDomain(it) }.lowercase()
        val email = required(tr("Let's Encrypt 邮箱", "Let's Encrypt email"), tr("请本人输入证书邮箱；没有默认值", "Type the certificate email yourself (no default)")) { Validation.validEmail(it) }
        val templates = checked(handle, "bash $REMOTE_ROOT/linux/05b-cover-site-polished.sh --list", emit = false)
        log(templates.stdout.trim())
        val template = required(tr("伪装站模板", "Cover template"), tr("R=随机，A=按域名稳定选择，或输入 1—15 指定模板", "R=random, A=stable per domain, or 1-15"), "R") { Validation.normalizeTemplate(it) != null }
        val normalizedTemplate = requireNotNull(Validation.normalizeTemplate(template))
        val publicIpResult = checked(handle, "ip=\$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); [ -n \"\$ip\" ] || ip=\$(hostname -I | awk '{print \$1}'); printf '%s\\n' \"\$ip\"", emit = false)
        val publicIp = publicIpResult.stdout.lines().map { it.trim() }.firstOrNull { runCatching { InetAddress.getByName(it) is Inet4Address }.getOrDefault(false) }
            ?: error(tr("无法确定 VPS 公网 IPv4", "Could not determine the VPS public IPv4"))
        waitForDns(domain, publicIp)

        val autoInput = "DOMAIN_B64=${Base64.encodeToString(domain.toByteArray(), Base64.NO_WRAP)}\n" +
            "EMAIL_B64=${Base64.encodeToString(email.toByteArray(), Base64.NO_WRAP)}\nLANG=zh\n"
        handle.upload(autoInput.toByteArray(), "proxy-runbook-auto-input", "/tmp", "0600")
        val command = "PROXY_RUNBOOK_LOGIN_USER=${SshHandle.shellQuote(handle.target.user)} PROXY_RUNBOOK_SSH_KEY_INSTALLED=1 PROXY_RUNBOOK_ASSUME_DEFAULTS=1 PROXY_RUNBOOK_GUI_MODE=1 PROXY_RUNBOOK_LANG=zh PROXY_RUNBOOK_COVER_TEMPLATE=${SshHandle.shellQuote(normalizedTemplate)} PROXY_RUNBOOK_AUTO_INPUT=/tmp/proxy-runbook-auto-input bash $REMOTE_ROOT/linux/00-auto-install-or-optimize.sh"
        val result = checked(handle, command, interactive = true)
        check(result.ok) { "remote convergence returned ${result.exitCode}" }
        showHandoff(handle)
        if (confirmYes(tr("打开面板前是否整理冗余备份，并只保留一份已验证的当前配置备份？", "Prune redundant remote backups and retain one verified current-config backup before opening the panel?"), false, allowNo = true)) {
            pruneBackups(handle, exactConfirmation = false)
        }
        return if (confirmYes(tr("现在通过本机 SSH 隧道打开 3x-ui 面板？", "Open the 3x-ui panel through a localhost SSH tunnel now?"), true, allowNo = true)) openPanel(handle) else false
    }

    private suspend fun uploadToolkit(handle: SshHandle) {
        log("Uploading embedded proxy-runbook v$VERSION...")
        val bytes = context.assets.open(TOOLKIT_ASSET).use { it.readBytes() }
        require(bytes.size > 128) { tr("APK 内嵌工具包为空", "embedded toolkit is empty") }
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
              test -x $REMOTE_ROOT/linux/00-auto-install-or-optimize.sh && test -x $REMOTE_ROOT/linux/18-panel-metadata.sh && test -x $REMOTE_ROOT/linux/22-dismantle-managed-node.sh && test -x $REMOTE_ROOT/linux/23-node-identity.sh && test -x $REMOTE_ROOT/linux/24-security-baseline.sh && test -x $REMOTE_ROOT/linux/25-security-events.sh && test -x $REMOTE_ROOT/linux/26-device-admission.sh && test -x $REMOTE_ROOT/linux/27-ip-rebind.sh && test -x $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh && test -x $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh && test -x $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh && test -x $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh && test -x $REMOTE_ROOT/linux/29-copyparty-drive.sh && test -x $REMOTE_ROOT/linux/30-copyparty-account.sh && test -x $REMOTE_ROOT/linux/31-copyparty-nginx.sh && test -s $REMOTE_ROOT/THIRD_PARTY_LOCK.env && test -s $REMOTE_ROOT/templates/copyparty/copyparty.conf.in && test -s $REMOTE_ROOT/templates/systemd/proxy-node-assistant-copyparty.service && test -s $REMOTE_ROOT/templates/nginx/proxy-node-assistant-copyparty.conf.in && test -s $REMOTE_ROOT/templates/cover-sites/MANIFEST.tsv && complete=1
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
			val publicEnv = ProtocolParsers.kv(checked(handle, "cat /etc/proxy-runbook/public.env", emit = false).stdout)
			val oldDomain = publicEnv["COVER_DOMAIN"].orEmpty().lowercase()
			check(Validation.validDomain(oldDomain)) { "IP_REBIND_BLOCKED_PRE_DNS: invalid managed construction domain" }
			val newDomain = required(tr("新施工域名", "New construction domain"), tr("直接确认表示保留原域名；更换域名会停在 Cloudflare 人工阶段", "Keep the default to retain the domain; a changed domain stops at the Cloudflare manual phase"), oldDomain) { Validation.validDomain(it) }.lowercase()
			val arguments = listOf(expected.currentPublicIp, newIp, oldDomain, newDomain).joinToString(" ") { SshHandle.shellQuote(it) }
			val preflight = checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh preflight $arguments", emit = false)
			val values = ProtocolParsers.kv(ProtocolParsers.markedBlock(preflight.stdout, "__PNA_IP_REBIND_PREFLIGHT_V1_BEGIN__", "__PNA_IP_REBIND_PREFLIGHT_V1_END__"))
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

    private suspend fun showHandoff(handle: SshHandle) {
        val command = "printf '%s\\n' '${ProtocolParsers.HANDOFF_BEGIN}'; cat /root/.config/proxy-runbook/HANDOFF-SECRETS.txt 2>/dev/null || true; printf '%s\\n' '${ProtocolParsers.HANDOFF_END}'"
        val result = checked(handle, command, emit = false)
        val legacy = ProtocolParsers.handoff(result.stdout)
        val login = ProtocolParsers.loginCredentialForm(legacy)
        val fields = linkedMapOf(
            "PNA_VERSION" to VERSION,
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
        runCatching { ProtocolParsers.kv(checked(handle, "cat /etc/proxy-runbook/public.env 2>/dev/null || true", emit = false).stdout) }.getOrNull()?.let { runtime ->
            runtime["PUBLIC_IP"]?.takeIf(ProtocolParsers::validCanonicalPublicIpv4)?.let { fields["VPS_PUBLIC_IP"] = it }
            runtime["COVER_DOMAIN"]?.takeIf(Validation::validDomain)?.let { fields["CONSTRUCTION_DOMAIN"] = it.lowercase() }
        }
        runCatching { ProtocolParsers.kv(checked(handle, "cat /etc/proxy-runbook/deployment-state.env 2>/dev/null || true", emit = false).stdout) }.getOrNull()?.let { deployment ->
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
                fields["PRIVATE_DRIVE_PUBLIC_ACCESS"] = "BLOCKED_PENDING_CLOUDFLARE"
                fields["PRIVATE_DRIVE_WEBDAV_LARGE_FILE_LIMIT"] = "OVER_100MB_NOT_SUPPORTED_VIA_CLOUDFLARE"
            } else {
                fields["PRIVATE_DRIVE_MODE"] = "disabled"
            }
        }
        val handoff = ProtocolParsers.completeHandoff(legacy, fields)
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
            tr("私人网盘控制中心", "Private drive control center"),
            tr(
                "当前阶段仅开放回环服务和 SSH 隧道；Cloudflare 橙云、Origin Rule 与公网端口保持阻断。\n[1] 安装/重建  [2] 脱敏状态  [3] 轮换账密  [4] SSH 隧道打开  [5] 生成 Nginx 候选  [6] 卸载并保留文件  [7] 永久清空",
                "This phase permits only the loopback service and SSH tunnel; Cloudflare, Origin Rule, and public ports remain blocked.\n[1] Install/rebuild  [2] Redacted status  [3] Rotate credentials  [4] Open SSH tunnel  [5] Generate Nginx candidate  [6] Uninstall/preserve data  [7] Permanent purge",
            ),
            PromptKind.TEXT,
            defaultValue = "2",
        ).trim().ifEmpty { "2" }
        return when (choice) {
            "1" -> { installOrRotateDrive(handle, false); false }
            "2" -> { checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh status"); false }
            "3" -> { installOrRotateDrive(handle, true); false }
            "4" -> openDriveTunnel(handle)
            "5" -> { prepareDriveCandidate(handle); false }
            "6" -> {
                confirmYes(tr("卸载 copyparty 服务但完整保留文件卷？", "Uninstall copyparty while preserving the complete data volume?"), false)
                val result = checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh uninstall-preserve")
                require("PNA_DRIVE_UNINSTALLED_DATA_PRESERVED" in result.stdout)
                false
            }
            "7" -> {
                val first = prompts.ask(tr("永久删除网盘", "Permanently delete drive"), tr("输入大写 DELETE DRIVE DATA；这不能由配置备份恢复。", "Type uppercase DELETE DRIVE DATA; configuration backups cannot restore these files."), PromptKind.EXACT_CONFIRMATION, danger = true)
                require(first == "DELETE DRIVE DATA") { tr("已取消永久删除", "Permanent deletion cancelled") }
                val second = prompts.ask(tr("最终确认", "Final confirmation"), tr("再次输入大写 PURGE-DATA", "Now type uppercase PURGE-DATA"), PromptKind.EXACT_CONFIRMATION, danger = true)
                require(second == "PURGE-DATA") { tr("已取消永久删除", "Permanent deletion cancelled") }
                val result = checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh purge PURGE-DATA")
                require("PNA_DRIVE_PURGED" in result.stdout)
                false
            }
            else -> error(tr("私人网盘选项无效", "Invalid private-drive selection"))
        }
    }

    private suspend fun cdnXhttpPrototype(handle: SshHandle) {
        val choice = prompts.ask(
            tr("CDN / XHTTP 实验控制中心", "CDN / XHTTP experimental control center"),
            tr(
                "橙云、Origin Rule、防火墙放行和公网 443 均被硬阻断。\n[1] 脱敏状态  [2] 创建/复用回环影子  [3] 复制严格校验的影子链接  [4] Cloudflare CIDR 只读计划  [5] 删除影子",
                "Orange-cloud, Origin Rule, firewall allowlisting, and public 443 are hard-blocked.\n[1] Redacted status  [2] Create/reuse loopback shadow  [3] Copy strictly validated staged link  [4] Read-only Cloudflare CIDR plan  [5] Remove shadow",
            ),
            PromptKind.TEXT,
            defaultValue = "1",
        ).trim().ifEmpty { "1" }
        when (choice) {
            "1" -> {
                val command = ". $REMOTE_ROOT/linux/lib-deployment-state.sh; pna_state_init_direct_if_missing; pna_state_show; " +
                    "if bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh show >/dev/null 2>&1; then echo XHTTP_COMPONENT=READY_LOOPBACK_ONLY; else echo XHTTP_COMPONENT=NOT_READY; fi; " +
                    "if grep -qF '# PNA_MANAGED_CDN_XHTTP_V095' /etc/nginx/sites-available/pna-cdn-xhttp-stage 2>/dev/null && ss -H -lntp 2>/dev/null | awk '\$4 == \"127.0.0.2:8443\" {found=1} END{exit found ? 0 : 1}'; then echo CDN_NGINX_STAGE=READY_LOOPBACK_ONLY; else echo CDN_NGINX_STAGE=NOT_READY; fi; " +
                    "echo CLOUDFLARE_MUTATION=NONE; echo PRODUCTION_443_PROMOTION=BLOCKED"
                checked(handle, command)
            }
            "2" -> {
                val domain = required(tr("施工域名", "Deployment hostname"), tr("输入已由当前证书覆盖的域名", "Enter the hostname covered by the current certificate")) { Validation.validDomain(it) }.lowercase()
                confirmYes(tr("确认只做回环验收，不修改 DNS、橙云、防火墙或公网 443？", "Confirm loopback validation only, without changing DNS, orange-cloud state, the firewall, or public 443?"), false)
                val ipResult = checked(handle, "ip=\$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); [ -n \"\$ip\" ] || ip=\$(hostname -I | awk '{print \$1}'); printf '%s\\n' \"\$ip\"", emit = false)
                val publicIp = ipResult.stdout.lines().map { it.trim() }.firstOrNull { runCatching { InetAddress.getByName(it) is Inet4Address }.getOrDefault(false) }
                    ?: error(tr("无法确定 VPS 公网 IPv4", "Could not determine the VPS public IPv4"))
                val create = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh create ${SshHandle.shellQuote(domain)}", emit = false)
                require("XHTTP_STATUS=READY" in create.stdout || "PNA_XHTTP_ALREADY_READY" in create.stdout)
                val stage = checked(handle, "bash $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh stage-local ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)}", emit = false)
                require("CDN_STAGE_SCOPE=LOCAL_ONLY" in stage.stdout)
                val validate = checked(handle, "bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)} --local-only", emit = false)
                require("CDN_LOCAL_VALIDATION=PASS" in validate.stdout && "PRODUCTION_443_PROMOTION=BLOCKED" in validate.stdout)
                log(tr("本地 XHTTP/Nginx 影子验收通过；公网与 Cloudflare 未修改。", "The local XHTTP/Nginx shadow passed; public and Cloudflare state were not changed."))
            }
            "3" -> {
                val domain = required(tr("施工域名", "Deployment hostname"), tr("输入创建影子时使用的域名", "Enter the hostname used to create the shadow")) { Validation.validDomain(it) }.lowercase()
                val result = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh link ${SshHandle.shellQuote(domain)} 8443", emit = false)
                val link = ProtocolParsers.kv(result.stdout)["XHTTP_LINK"].orEmpty()
                val profile = ProtocolParsers.cdnXHttpLink(link)
                require(profile.domain == domain && profile.port == 8443)
                _state.update { current ->
                    current.copy(secretHandoff = buildString {
                        appendLine("===== PNA CDN XHTTP LOCAL STAGE v0.9.5 =====")
                        appendLine("DEPLOYMENT_MODE=cdn-xhttp-tls")
                        appendLine("ACTIVE_MODE=WAITING_FOR_CLOUDFLARE_MANUAL_ACTION")
                        appendLine("CDN_XHTTP_STAGE_LINK=$link")
                        appendLine("CDN_XHTTP_STAGE_REACHABILITY=LOOPBACK_VALIDATED_NOT_PUBLIC")
                        appendLine("CLOUDFLARE_DNS_PROXY=DEFERRED")
                        appendLine("CLOUDFLARE_ORIGIN_LOCK=DEFERRED")
                        append("PRODUCTION_443_PROMOTION=BLOCKED")
                    })
                }
                log(tr("影子链接已严格校验；只在受保护交接区显示。", "The staged link passed strict validation and is visible only in the protected handoff panel."))
            }
            "4" -> {
                checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh fetch")
                val plan = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh plan ${handle.target.port}")
                require("PLAN_ONLY=1" in plan.stdout && "CLOUDFLARE_FIREWALL_APPLIED=0" in plan.stdout)
            }
            "5" -> {
                val exact = prompts.ask(tr("删除本地影子", "Remove local shadow"), tr("输入大写 REMOVE XHTTP STAGE；原 Reality 443 保持不动", "Type uppercase REMOVE XHTTP STAGE; the original Reality 443 is retained"), PromptKind.EXACT_CONFIRMATION, danger = true)
                require(exact == "REMOVE XHTTP STAGE") { tr("已取消删除", "Removal cancelled") }
                val command = "bash $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh disable-stage && bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh delete && " +
                    ". $REMOTE_ROOT/linux/lib-deployment-state.sh; current=\$(pna_state_env_value ACTIVE_MODE || true); " +
                    "if [ \"\$current\" = WAITING_FOR_CLOUDFLARE_MANUAL_ACTION ] || [ \"\$current\" = CDN_STAGED_8443 ]; then " +
                    "ss -H -lntp 2>/dev/null | grep -E ':[4]43[[:space:]].*[x]ray' >/dev/null || exit 139; pna_state_transition \"\$current\" ACTIVE_DIRECT direct-reality xray-reality previously-exposed; fi; echo PNA_CDN_LOCAL_PROTOTYPE_REMOVED"
                val result = checked(handle, command)
                require("PNA_CDN_LOCAL_PROTOTYPE_REMOVED" in result.stdout)
            }
            else -> error(tr("CDN/XHTTP 选项无效", "Invalid CDN/XHTTP selection"))
        }
    }

    private suspend fun installOrRotateDrive(handle: SshHandle, rotate: Boolean) {
        val username = required(
            tr("网盘账户名", "Drive username"),
            tr("3—32 位，英文字母开头，仅允许字母、数字、点、下划线、连字符", "3-32 characters, starting with a letter; letters, digits, dot, underscore, and hyphen only"),
            "pnaadmin",
        ) { Regex("^[A-Za-z][A-Za-z0-9._-]{2,31}$").matches(it) }
        val quota = required(tr("网盘容量", "Drive quota"), tr("20GB 参考机只允许 2 或 3 GiB", "The 20GB reference profile permits only 2 or 3 GiB"), "2") { it == "2" || it == "3" }
        val policy = prompts.ask(tr("密码策略", "Password policy"), tr("[1] 安全随机生成（推荐）  [2] 自定义遮罩输入两次", "[1] Secure random (recommended)  [2] Custom, entered twice in masked fields"), PromptKind.TEXT, defaultValue = "1").trim().ifEmpty { "1" }
        val password = when (policy) {
            "1" -> ByteArray(30).also(SecureRandom()::nextBytes).let { Base64.encodeToString(it, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) }
            "2" -> {
                val first = Validation.singleLineSecret(prompts.ask(tr("网盘密码", "Drive password"), tr("输入 14—128 位可打印 ASCII；空格不会被修剪", "Enter 14-128 printable ASCII characters; spaces are not trimmed"), PromptKind.SECRET))
                val second = Validation.singleLineSecret(prompts.ask(tr("确认网盘密码", "Confirm drive password"), tr("再次输入同一密码", "Enter the same password again"), PromptKind.SECRET))
                require(first == second) { tr("两次密码不一致", "The passwords do not match") }
                require(Regex("^[\\x20-\\x7e]{14,128}$").matches(first)) { tr("密码必须是 14—128 位可打印 ASCII", "Password must contain 14-128 printable ASCII characters") }
                first
            }
            else -> error(tr("密码策略无效", "Invalid password policy"))
        }
        confirmYes(tr("将校验固定 release 与 SHA-256，并执行无 Cookie 登录/上传/下载/删除验收。继续？", "The pinned release and SHA-256 will be verified, followed by a cookie-free login/upload/download/delete transaction. Continue?"), false)
        val verb = if (rotate) "rotate" else "install"
        val command = "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh $verb ${SshHandle.shellQuote(username)} $quota"
        val result = handle.exec(command, root = true, stdinBytes = (password + "\n").toByteArray(), log = ::log)
        check(result.ok) { "private-drive transaction failed (${result.exitCode}): ${result.stderr.takeLast(1200)}" }
        listOf("PNA_DRIVE_CREDENTIAL_CRUD_OK", "COPYPARTY_LISTEN=127.0.0.1:3923", "PRIVATE_DRIVE_PUBLIC_ACCESS=BLOCKED").forEach { require(it in result.stdout) }
        _state.update { current ->
            current.copy(secretHandoff = buildString {
                appendLine("===== PNA PRIVATE DRIVE HANDOFF v0.9.5 =====")
                appendLine("PRIVATE_DRIVE_STATUS=LOCAL_ONLY_READY_WAITING_FOR_CLOUDFLARE")
                appendLine("PRIVATE_DRIVE_ENGINE=copyparty")
                appendLine("COPYPARTY_VERSION=v1.20.21")
                appendLine("DRIVE_ACCOUNT_USERNAME=$username")
                appendLine("DRIVE_ACCOUNT_PASSWORD=$password")
                appendLine("PRIVATE_DRIVE_QUOTA_GIB=$quota")
                appendLine("PRIVATE_DRIVE_LOCAL_ORIGIN=http://127.0.0.1:3923/")
                appendLine("PRIVATE_DRIVE_PUBLIC_URL=PENDING_CLOUDFLARE_ORIGIN_RULE")
                append("WEBDAV_OVER_CLOUDFLARE_LARGE_PUT=UNSUPPORTED")
            })
        }
        log("PRIVATE_DRIVE_CREDENTIAL_HANDOFF_READY; secret is visible only in the protected handoff panel")
    }

    private suspend fun openDriveTunnel(handle: SshHandle): Boolean {
        val status = checked(handle, "bash $REMOTE_ROOT/linux/29-copyparty-drive.sh status", emit = false)
        require("COPYPARTY_SERVICE=active" in status.stdout && "COPYPARTY_LOOPBACK_LISTENER=1" in status.stdout) { tr("copyparty 本地回源未就绪", "The copyparty loopback origin is not ready") }
        val forward = handle.openLocalForward(3923)
        val url = "http://127.0.0.1:${forward.localPort}/"
        TunnelRegistry.install(context, handle, forward, url)
        activeHandle = null
        _state.update { it.copy(panelUrl = url) }
        log("PRIVATE_DRIVE_TUNNEL_ACTIVE url=$url")
        return true
    }

    private suspend fun prepareDriveCandidate(handle: SshHandle) {
        val hostname = required(tr("独立网盘 hostname", "Separate drive hostname"), tr("例如 drive.example.com；当前只生成候选，不改 Cloudflare", "For example drive.example.com; this only generates a candidate and does not change Cloudflare")) { Validation.validDomain(it) }.lowercase()
        val port = required(tr("Origin Rule 目标端口", "Origin Rule destination port"), tr("只允许 2053 / 2083 / 2087 / 2096", "Only 2053 / 2083 / 2087 / 2096 are allowed"), "2087") { it in setOf("2053", "2083", "2087", "2096") }
        val result = checked(handle, "bash $REMOTE_ROOT/linux/31-copyparty-nginx.sh prepare ${SshHandle.shellQuote(hostname)} $port")
        require("PNA_DRIVE_NGINX_NOT_ENABLED=WAITING_FOR_CLOUDFLARE_AND_CERTIFICATE" in result.stdout)
        log(tr("只生成 root-only 候选；没有公网监听，也没有修改 Cloudflare。", "Only a root-only candidate was generated; no public listener or Cloudflare state changed."))
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
        val env = ProtocolParsers.kv(checked(handle, "cat /etc/proxy-runbook/public.env", emit = false).stdout)
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
            dirs=(/opt/proxy-runbook-v0.5 /opt/proxy-runbook-v0.6 /opt/proxy-runbook-v0.6.1 /opt/proxy-runbook-v0.6.2 /opt/proxy-runbook-v0.6.5 /opt/proxy-runbook-v0.6.6 /opt/proxy-runbook-v0.7.1 /opt/proxy-runbook-v0.7.4 /opt/proxy-runbook-v0.8.2 /opt/proxy-runbook-v0.8.4 /opt/proxy-runbook-v0.8.5 /opt/proxy-runbook-v0.8.6 /opt/proxy-runbook-v0.9.0 /opt/proxy-runbook-v0.9.5)
            for target in "${'$'}{dirs[@]}"; do [ ! -e "${'$'}target" ] || { [ -d "${'$'}target" ] && [ ! -L "${'$'}target" ]; } || exit 61; done
            [ ! -e /opt/proxy-runbook-current ] || [ -L /opt/proxy-runbook-current ] || exit 62
            printf 'PROXY_RUNBOOK_UNINSTALL_BEGIN\n'
            rm -f /opt/proxy-runbook-current /usr/local/sbin/proxy-node /tmp/proxy-runbook-toolkit-v*.tar.gz
            for target in "${'$'}{dirs[@]}"; do [ ! -d "${'$'}target" ] || rm -rf -- "${'$'}target"; done
            printf 'PRESERVED=NODE_SERVICES_AND_CONFIG\nPROXY_RUNBOOK_UNINSTALL_END\n'
        """.trimIndent()
        val result = checked(handle, command)
        require("PROXY_RUNBOOK_UNINSTALL_BEGIN" in result.stdout && "PROXY_RUNBOOK_UNINSTALL_END" in result.stdout) { tr("远端返回缺少完整卸载标记", "complete uninstall markers were missing") }
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
        val plan = checked(handle, "bash $REMOTE_ROOT/linux/22-dismantle-managed-node.sh --plan")
        require("PNA_DISMANTLE_PLAN_BEGIN" in plan.stdout && "PNA_DISMANTLE_PLAN_END" in plan.stdout) { tr("远端返回缺少完整拆除计划标记", "complete dismantle plan markers are missing") }
        required(tr("全量拆除并恢复基线", "Full dismantle"), tr("请输入大写 RESTORE ORIGINAL。任何拆除前都会先下载救援包。", "Type uppercase RESTORE ORIGINAL. A rescue archive is downloaded before any removal.")) { it == "RESTORE ORIGINAL" }
        val legacy = "RESTORE_GRADE=LEGACY_UNCERTAIN" in plan.stdout
        if (legacy) required(tr("旧版本限制", "Legacy limitation"), tr("请输入大写 LEGACY FULL RESTORE，确认接受在没有逐字节原始基线时执行有界拆除。", "Type uppercase LEGACY FULL RESTORE to accept bounded removal without a byte-for-byte baseline.")) { it == "LEGACY FULL RESTORE" }
        val backup = checked(handle, "bash $REMOTE_ROOT/linux/01-safe-backup.sh")
        require("BACKUP_OK" in backup.stdout) { tr("拆除前救援备份失败", "pre-dismantle backup failed") }
        val remote = Regex("/root/proxy-node-backup-[0-9]{8}-[0-9]{6}\\.tar\\.gz").find(backup.stdout)?.value ?: error(tr("远端返回缺少救援包路径", "rescue archive path missing"))
        val bytes = handle.downloadBytes(remote)
        require(bytes.size > 1024) { tr("下载的救援包异常过小", "downloaded rescue archive is unexpectedly small") }
        val directory = File(context.filesDir, "rescue").apply { mkdirs() }
        val file = File(directory, remote.substringAfterLast('/')).apply { writeBytes(bytes) }
        _state.update { it.copy(downloadedFile = file.absolutePath) }
        log("RESCUE_ARCHIVE_DOWNLOADED ${file.name}")
        val env = if (legacy) "PNA_DISMANTLE_CONFIRM=RESTORE_ORIGINAL PNA_LEGACY_FULL=1" else "PNA_DISMANTLE_CONFIRM=RESTORE_ORIGINAL"
        val result = checked(handle, "$env bash $REMOTE_ROOT/linux/22-dismantle-managed-node.sh --execute", interactive = true)
        listOf("PNA_DISMANTLE_BEGIN", "SSH_ACCESS_PRESERVED=1", "PRESERVED_SHARED_BASE_PACKAGES=1", "PNA_DISMANTLE_END").forEach { require(it in result.stdout) { "dismantle marker $it missing; rescue retained" } }
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
                    require("PNA_SECURITY_BASELINE_APPLIED" in applied.stdout && "PNA_SECURITY_BASELINE_STATUS_END" in applied.stdout) { tr("安全基线返回不完整", "Security-baseline response was incomplete") }
                    log(applied.stdout.trim())
                }
                "4" -> {
                    val status = checked(handle, "bash $REMOTE_ROOT/linux/24-security-baseline.sh --status", emit = false)
                    require("PNA_SECURITY_BASELINE_STATUS_BEGIN" in status.stdout && "PNA_SECURITY_BASELINE_STATUS_END" in status.stdout) { tr("安全基线状态返回不完整", "Security-baseline status was incomplete") }
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
                    require("__PNA_SECURITY_V1_BEGIN__" in result.stdout && "__PNA_SECURITY_V1_END__" in result.stdout && "SUMMARY\t" in result.stdout) { tr("安全事件协议返回不完整", "Security-event protocol response was incomplete") }
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
                append("PER_DEVICE_VLESS=SUPPORTED; hardware-uncloneable lock is not claimed")
            })
            if (status.activeControllers == 0) {
                val answer = prompts.ask(
                    tr("登记首个控制设备", "Register the first controller"),
                    tr("此节点还没有 controller。把当前 Android 设备登记为首个 controller？[Y/n]", "This node has no controller. Register this Android device as the first controller? [Y/n]"),
                    PromptKind.YES_NO,
                    defaultValue = "y",
                ).trim().lowercase()
                if (answer in setOf("y", "yes", "是", "")) {
                    val label = required(tr("设备名称", "Device label"), tr("1—64 位安全字符，例如 Android Phone", "1-64 safe characters, for example Android Phone"), "Android Phone") { Regex("^[A-Za-z0-9._ -]{1,64}$").matches(it) }
                    val input = "\n${identity.publicValue}\n$label\ncontroller\n\n".toByteArray()
                    val result = handle.exec("bash $REMOTE_ROOT/linux/26-device-admission.sh bootstrap-controller", root = true, stdinBytes = input, log = ::log)
                    check(result.ok && "__PNA_DEVICE_BOOTSTRAP_V1_END__" in result.stdout) { "First-controller bootstrap failed (${result.exitCode}): ${result.stderr.takeLast(1000)}" }
                    continue
                }
            }
            val choice = prompts.ask(
                tr("设备准入", "Device admission"),
                tr(
                    "[1] 刷新  [2] 显示本机公开身份  [3] 创建 10 分钟单次邀请  [4] 响应邀请  [5] 批准响应  [6] 暂停  [7] 恢复  [8] 吊销  [9] 当前设备节点  [0] 返回",
                    "[1] Refresh  [2] Show local public identity  [3] Create 10-minute invitation  [4] Respond  [5] Approve  [6] Pause  [7] Resume  [8] Revoke  [9] Current-device nodes  [0] Back",
                ),
                PromptKind.TEXT,
                defaultValue = "1",
            ).trim().ifEmpty { "1" }
            when (choice) {
                "1" -> Unit
                "2" -> _state.update { it.copy(secretHandoff = "DEVICE_ID=${identity.deviceId}\nPUBLIC_KEY=${identity.publicValue}\nPRIVATE_IDENTITY_STORAGE=ANDROID_KEYSTORE_ENCRYPTED_APP_VAULT") }
                "3" -> {
                    val result = checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh create-invite ${SshHandle.shellQuote(identity.deviceId)}", emit = false)
                    val invite = DeviceAdmissionProtocol.parseInviteOutput(result.stdout)
                    _state.update { it.copy(secretHandoff = DeviceAdmissionProtocol.encodeInvite(invite)) }
                }
                "4" -> {
                    val bundle = required(tr("粘贴邀请", "Paste invitation"), "PNAINV1…") { it.startsWith("PNAINV1.") }
                    val invite = DeviceAdmissionProtocol.decodeInvite(bundle)
                    val label = required(tr("设备名称", "Device label"), tr("1—64 位安全字符", "1-64 safe characters"), "Android Phone") { Regex("^[A-Za-z0-9._ -]{1,64}$").matches(it) }
                    val roleChoice = prompts.ask(tr("设备角色", "Device role"), tr("[1] 仅流量（默认）  [2] controller", "[1] Traffic-only (default)  [2] controller"), PromptKind.TEXT, defaultValue = "1").trim().ifEmpty { "1" }
                    val role = if (roleChoice == "2") "controller" else "traffic-only".also { require(roleChoice == "1") }
                    val response = DeviceAdmissionProtocol.response(invite, identity, label, role, deviceIdentity::sign)
                    _state.update { it.copy(secretHandoff = DeviceAdmissionProtocol.encodeResponse(response)) }
                }
                "5" -> {
                    val bundle = required(tr("粘贴响应", "Paste response"), "PNARESP1…") { it.startsWith("PNARESP1.") }
                    val response = DeviceAdmissionProtocol.decodeResponse(bundle)
                    require(response.nodeId == status.nodeId) { tr("响应不属于当前节点", "The response belongs to another node") }
                    val input = "${response.nonce}\n${response.publicValue}\n${response.label}\n${response.role}\n${response.signature}\n".toByteArray()
                    val result = handle.exec("bash $REMOTE_ROOT/linux/26-device-admission.sh enroll", root = true, stdinBytes = input, log = ::log)
                    check(result.ok && "NONCE_CONSUMED=1" in result.stdout) { "Device enrollment failed (${result.exitCode}): ${result.stderr.takeLast(1000)}" }
                    log(tr("设备已登记；签名已验证，邀请已消费且不能重放。", "The device was enrolled; its signature was verified and the invitation cannot be replayed."))
                }
                "6", "7", "8" -> {
                    val target = required("DEVICE_ID", "pna-device-…") { Regex("^pna-device-[a-z2-7]{26}$").matches(it) }
                    val verb = mapOf("6" to "pause", "7" to "resume", "8" to "revoke").getValue(choice)
                    if (verb == "revoke") confirmYes(tr("吊销会立即删除该设备的受管 VLESS；继续？", "Revocation immediately removes this device's managed VLESS credentials. Continue?"), false)
                    checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh $verb ${SshHandle.shellQuote(identity.deviceId)} ${SshHandle.shellQuote(target)}")
                }
                "9" -> {
                    val result = checked(handle, "bash $REMOTE_ROOT/linux/26-device-admission.sh handoff ${SshHandle.shellQuote(identity.deviceId)}", emit = false)
                    val block = result.stdout.substringAfter("__PNA_DEVICE_HANDOFF_V1_BEGIN__\n", "").substringBefore("\n__PNA_DEVICE_HANDOFF_V1_END__", "")
                    require("DIRECT_REALITY_LINK=vless://" in block) { "Device handoff protocol validation failed" }
                    _state.update { it.copy(secretHandoff = block) }
                }
                "0" -> return
                else -> error(tr("设备准入选项无效", "Invalid device-admission selection"))
            }
        }
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
        const val VERSION = "0.9.5"
        const val BUILD_ID = "20260824-v095-complete-login-handoff-v8"
        const val BUILD_REVISION = 8
        const val REMOTE_ROOT = "/opt/proxy-runbook-current"
        const val INSTALL_ROOT = "/opt/proxy-runbook-v0.9.5"
        const val TOOLKIT_ASSET = "proxy-runbook-toolkit-v0.9.5.tgz"
        const val TOOLKIT_ARCHIVE = "proxy-runbook-toolkit-v0.9.5.tar.gz"
		const val CLOUDFLARE_DNS_DASHBOARD = "https://dash.cloudflare.com/?to=%2F%3Aaccount%2F%3Azone%2Fdns%2Frecords"
    }
}
