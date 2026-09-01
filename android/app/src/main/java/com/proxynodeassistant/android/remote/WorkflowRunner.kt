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
import com.proxynodeassistant.android.model.Language
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
import java.util.Locale

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
                // Actions 3 and 19 deliberately inspect the handset before SSH is opened.
                // This keeps the local egress observation separate from the VPS view and
                // prevents a proxy/TUN setting from being silently presented as the source.
                val localObservation = if (action.code.equals("3", true) || action.code.equals("19", true)) {
                    log("LOCAL_PUBLIC_IPV4_DETECTION=START (direct HTTP lookups; app proxy bypassed)")
                    try {
                        AndroidNetworkProbes.detectPublicIpv4().also { observation ->
                            log("LOCAL_PUBLIC_IPV4=${observation.ip} SOURCES=${observation.quorum}")
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        log("LOCAL_PUBLIC_IPV4_DETECTION=FAILED detail=${safeError(error)}")
                        null
                    }
                } else null
                handle = connect(target, authMode, suppliedPassword)
                activeHandle = handle
                _state.update { it.copy(status = RunStatus.RUNNING) }
                tunnelTransferred = execute(action.code.uppercase(), handle, localObservation)
                _state.update { it.copy(status = RunStatus.SUCCEEDED) }
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

    private suspend fun execute(code: String, handle: SshHandle, localObservation: AndroidPublicIpObservation? = null): Boolean = when (code) {
        "1" -> deploy(handle)
        "2" -> openPanel(handle)
        "3" -> { ensureToolkit(handle); diagnoseWithLocalRoutes(handle, localObservation); false }
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
        "19" -> { ensureToolkit(handle); manageSS2022Allowlist(handle, localObservation); false }
        "T" -> { ensureToolkit(handle); trafficEstimate(handle); log("Provider API profiles are managed from the local Provider screen."); false }
        else -> error(tr("操作 $code 属于本地功能或远端执行器暂不支持", "Action $code is local or unsupported in the remote runner"))
    }

    /**
     * Keep the existing remote doctor, then add handset-origin probes.  The probes are
     * intentionally layered: they establish TCP/TLS/HTTPS reachability only and never
     * claim that a VLESS or Shadowsocks data session has been authenticated.
     */
    private suspend fun diagnoseWithLocalRoutes(handle: SshHandle, localObservation: AndroidPublicIpObservation?) {
        var remoteFailure: Throwable? = null
        try {
            checked(handle, "bash $REMOTE_ROOT/linux/16-auto-diagnose.sh --protocol-v1")
        } catch (error: CancellationException) {
            // Do not turn an explicit user cancellation into a delayed diagnostic
            // failure; abort before opening any handset-side probes.
            throw error
        } catch (error: Throwable) {
            remoteFailure = error
            log("REMOTE_DOCTOR=FAILED detail=${safeError(error)}")
        }

        val metadata = readRuntimeMetadata(handle)
        log("")
        log(tr("—— 当前本地链路 → VPS 三协议到达性 ——", "—— CURRENT LOCAL PATH -> VPS THREE-PROTOCOL REACHABILITY ——"))
        log(tr("GOOD 仅表示对应网络/TLS/边缘层已到达，不等同于 VLESS/SS 吞吐或完整认证。", "GOOD means the named network/TLS/edge layer was reached; it is not a VLESS/SS throughput or full-authentication test."))
        localObservation?.let { log("LOCAL_PUBLIC_IPV4=${it.ip} SOURCES=${it.quorum}") }

        // The reconciled topology is authoritative once it exists.  INSTALL_PLAN_ROUTE_MODE
        // is only the bootstrap/public-env fallback; preferring it would leave action [3]
        // probing a stale route after a later gray/orange reconciliation.
        val routeModeRaw = sequenceOf(
            metadata["TOPOLOGY_MODE"],
            metadata["ROUTE_MODE"],
            metadata["INSTALL_PLAN_ROUTE_MODE"],
        ).filterNotNull().firstOrNull { it.isNotBlank() }.orEmpty().lowercase(Locale.ROOT)
        // Deployment-state files use the managed-* spelling while public.env uses the
        // short route name. Normalize both so an older toolkit and the v1 toolkit
        // produce the same probe matrix.
        val routeMode = when (routeModeRaw) {
            "managed-orange" -> "orange"
            "managed-gray" -> "gray"
            "managed-dual" -> "dual"
            else -> routeModeRaw
        }
        val realityPort = metadata["REALITY_PRODUCTION_PORT"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: 443
        val realitySni = metadata["COVER_DOMAIN"].orEmpty().takeIf { Validation.validDomain(it) }
        if (routeMode == "orange") {
            log(tr("[SKIP] REALITY：当前拓扑未配置灰云 Reality 路由。", "[SKIP] REALITY: the current topology has no gray/Reality route."))
        } else {
            val probe = AndroidNetworkProbes.realityProbe(handle.target.host, realityPort, realitySni)
            logRouteProbe(probe)
            if (realitySni == null) log(tr("  未找到 Reality SNI，本次只把 TLS 尝试作为分层探测。", "  No Reality SNI was found; this is only a layered TLS attempt."))
        }

        val orangeDomain = sequenceOf(metadata["ORANGE_DOMAIN"], metadata["CDN_EDGE_DOMAIN"], metadata["COVER_DOMAIN"])
            .filterNotNull().firstOrNull { Validation.validDomain(it) }
        val orangePort = metadata["CDN_EDGE_PORT"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: 8443
        if (routeMode == "gray") {
            log(tr("[SKIP] CDN_XHTTP：当前拓扑未配置橙云/XHTTP 路由。", "[SKIP] CDN_XHTTP: the current topology has no orange-cloud/XHTTP route."))
        } else if (orangeDomain != null) {
            logRouteProbe(AndroidNetworkProbes.cdnHttpsProbe(orangeDomain, orangePort))
        } else {
            log(tr("[SKIP] CDN_XHTTP：运行态没有可验证的橙云域名。", "[SKIP] CDN_XHTTP: no verifiable orange-cloud hostname is present in runtime metadata."))
        }

        val ssPort = metadata["SS2022_PORT"]?.toIntOrNull()?.takeIf { Ss2022PortPolicy.valid(it) }
            ?: Ss2022PortPolicy.FORMAL_PORT
        logRouteProbe(AndroidNetworkProbes.tcpProbe("SS2022", handle.target.host, ssPort))
        remoteFailure?.let { throw it }
    }

    private suspend fun readRuntimeMetadata(handle: SshHandle): Map<String, String> {
        // The v1 scripts are intentionally compatible with the v0.9.x state layout.
        // Emit lower-priority files first because ProtocolParsers.kv keeps the last
        // occurrence of a key: the new topology file wins over its legacy fallback,
        // while edge-state fills in ORANGE/CDN fields absent from public.env.
        val command = """
            cat /etc/proxy-runbook/public.env 2>/dev/null || true
            cat /etc/text-node-assistant/public.env 2>/dev/null || true
            cat /etc/proxy-runbook/deployment-state.env 2>/dev/null || true
            cat /etc/text-node-assistant/deployment-state.env 2>/dev/null || true
            cat /etc/proxy-runbook/cloudflare/edge-state.env 2>/dev/null || true
            cat /etc/text-node-assistant/cloudflare/edge-state.env 2>/dev/null || true
            cat /root/.config/text-node-assistant/topology.env 2>/dev/null || true
            cat /root/.config/proxy-node-assistant/topology.env 2>/dev/null || true
            if systemctl is-active --quiet tna-ss2022-112-trial.service 2>/dev/null; then
              trial_port=""
              if [ -r /run/tna-ss2022-112-trial.json ] && command -v jq >/dev/null 2>&1; then
                trial_port="${'$'}(jq -r '.inbounds[0].port // empty' /run/tna-ss2022-112-trial.json 2>/dev/null || true)"
              fi
              [ -n "${'$'}trial_port" ] || trial_port="${Ss2022PortPolicy.TRIAL_PORT}"
              printf 'SS2022_PORT=%s\n' "${'$'}trial_port"
            fi
            cat /etc/proxy-runbook/ss2022/service.env 2>/dev/null || true
        """.trimIndent()
        return try {
            val result = checked(handle, command, emit = false)
            ProtocolParsers.kv(result.stdout)
        } catch (error: Throwable) {
            log("RUNTIME_ROUTE_METADATA=UNAVAILABLE detail=${safeError(error)}")
            emptyMap()
        }
    }

    private suspend fun logRouteProbe(probe: AndroidRouteProbe) {
        val state = if (probe.ok) "GOOD" else "FAIL"
        log("[$state] ${probe.name} layer=${probe.layer} target=${probe.target} time=${probe.elapsedMs}ms detail=${probe.detail}")
    }

    /** Add exactly the source observed by sshd, never a CIDR or a guessed subnet. */
    private suspend fun manageSS2022Allowlist(handle: SshHandle, initialLocal: AndroidPublicIpObservation?) {
        val local = initialLocal ?: run {
            try {
                AndroidNetworkProbes.detectPublicIpv4().also { log("LOCAL_PUBLIC_IPV4_RETRY=${it.ip} SOURCES=${it.quorum}") }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log("LOCAL_PUBLIC_IPV4_RETRY=FAILED detail=${safeError(error)}")
                null
            }
        }

        // SSH_CONNECTION is read in the login shell (not through sudo), because sudo may
        // intentionally strip connection metadata. This value is the authoritative source
        // that the VPS firewall can actually match.
        val observedResult = handle.exec(
            "printf '%s\\n' \"\$SSH_CONNECTION\" | awk '{print \$1}'",
            root = false,
            log = { },
        )
        check(observedResult.ok) { "SSH source inspection failed (exit ${observedResult.exitCode})" }
        val observed = AndroidNetworkProbes.normalizePublicIpv4(observedResult.stdout)
            ?: error(tr("VPS 未报告有效的公网 IPv4 SSH 来源", "The VPS did not report a valid public IPv4 for this SSH session"))
        log("VPS_SEES_SSH_SOURCE=$observed")
        if (local != null && local.ip != observed) {
            log(tr("[WARN] 本机多源结果与 VPS 看到的 SSH 来源不一致；白名单只采用 VPS 实际看到的来源。", "[WARN] The local observation differs from the source seen by the VPS; only the VPS-observed source will be allowlisted."))
        }

        // Keep the status exit code authoritative; appending `; list` would mask a
        // missing/inactive service because the list command exits successfully.
        val status = handle.exec("bash $REMOTE_ROOT/linux/23-ss2022-tcp.sh status", root = true, log = ::log)
        check(status.ok) { "SS2022 status failed (exit ${status.exitCode})" }
        val statusValues = ProtocolParsers.kv(status.stdout)
        check(statusValues["PRESENT"] == "1" && statusValues["ACTIVE"] == "1" && statusValues["LISTENER"] == "1" && statusValues["FIREWALL"] == "1") {
            "SS2022 service is not ready (PRESENT=${statusValues["PRESENT"] ?: "?"}, ACTIVE=${statusValues["ACTIVE"] ?: "?"}, LISTENER=${statusValues["LISTENER"] ?: "?"}, FIREWALL=${statusValues["FIREWALL"] ?: "?"})"
        }
        val list = handle.exec("bash $REMOTE_ROOT/linux/23-ss2022-tcp.sh list", root = true, log = ::log)
        check(list.ok) { "SS2022 allowlist listing failed (exit ${list.exitCode})" }
        val statusOutput = status.stdout + "\n" + list.stdout
        val statusSummary = statusOutput.lines().filter { it.contains("PNA_SS2022_") || it.startsWith("PORT=") || it.startsWith("ALLOWLIST_COUNT=") || it.startsWith("SOURCE=") }.joinToString(" ")
        if (statusSummary.isNotBlank()) log("SS2022_STATUS $statusSummary")

        val answer = prompts.ask(
            tr("添加 SS2022 白名单", "Add SS2022 allowlist entry"),
            tr(
                "本机探测=${local?.ip ?: "未知"}；VPS 实际看到的 SSH 来源=$observed。是否把精确地址 $observed 加入 SS2022 TCP 白名单？不会添加网段。",
                "Local observation=${local?.ip ?: "unknown"}; VPS-observed SSH source=$observed. Add the exact address $observed to the SS2022 TCP allowlist? No network range will be added.",
            ),
            PromptKind.YES_NO,
            defaultValue = "n",
            danger = true,
        )
        val yes = answer.trim().equals("y", true) || answer.trim().equals("yes", true) || answer.trim() == "是"
        if (!yes) {
            log("SS2022_ALLOWLIST=UNCHANGED")
            return
        }

        val update = checked(handle, "bash $REMOTE_ROOT/linux/23-ss2022-tcp.sh allow ${SshHandle.shellQuote(observed)}")
        check("PNA_SS2022_ALLOW_ADDED=$observed" in update.stdout) { "SS2022 allowlist update marker missing" }
        val verifiedStatus = checked(handle, "bash $REMOTE_ROOT/linux/23-ss2022-tcp.sh status", emit = false)
        val verifiedList = checked(handle, "bash $REMOTE_ROOT/linux/23-ss2022-tcp.sh list", emit = false)
        log("SS2022_ALLOWLIST=UPDATED source=$observed")
        val verifiedOutput = verifiedStatus.stdout + "\n" + verifiedList.stdout
        verifiedOutput.lines().filter { it.startsWith("PRESENT=") || it.startsWith("ACTIVE=") || it.startsWith("LISTENER=") || it.startsWith("FIREWALL=") || it.startsWith("PORT=") || it.startsWith("ALLOWLIST_COUNT=") || it.startsWith("SOURCE=") }.forEach { log("  $it") }

        val port = ProtocolParsers.kv(verifiedOutput)["PORT"]?.toIntOrNull()?.takeIf { Ss2022PortPolicy.valid(it) }
            ?: Ss2022PortPolicy.FORMAL_PORT
        logRouteProbe(AndroidNetworkProbes.tcpProbe("SS2022", handle.target.host, port))
    }

    private suspend fun deploy(handle: SshHandle): Boolean {
        val probe = probe(handle)
        val comparison = if (probe.installed) ProtocolParsers.compareVersions(probe.version, VERSION) else -1
        val needsUpload = when {
            !probe.installed -> true
            comparison > 0 -> error(tr("远端工具包 v${probe.version} 更新，请改用同版或更新的 Android 客户端", "Remote toolkit v${probe.version} is newer; use a matching or newer Android client"))
            comparison == 0 && !probe.complete -> error(tr("远端 v$VERSION 工具包不完整，请先执行 [13] 卸载，再重新安装", "Remote v$VERSION is incomplete. Explicitly uninstall with action 13 before reinstalling"))
            comparison == 0 && (probe.buildRevision > BUILD_REVISION || (probe.buildRevision == BUILD_REVISION && probe.buildId != BUILD_ID)) -> error(tr("远端 v$VERSION 构建更新或不同，已拒绝降级", "Remote v$VERSION build is newer or different; downgrade refused"))
            comparison == 0 && probe.buildRevision == BUILD_REVISION && probe.buildId == BUILD_ID -> false
            else -> true
        }
        val existingNode = detectExistingNode(handle)
        val existingSs2022Port = if (existingNode) detectExistingSs2022Port(handle) else null
        existingSs2022Port?.let { log("SS2022_EXISTING_PORT=$it (upgrade default preserves the existing listener)") }
        val plan = collectInstallPlan(existingNode, existingSs2022Port)
        plan.validate(existingNode)
        val review = plan.reviewLines().joinToString("\n")
        val apply = prompts.ask(
            tr("施工计划最终确认", "Final install-plan confirmation"),
            tr("请逐项核对。只有输入大写 APPLY 才会上传或修改 VPS：\n$review", "Review every item. No toolkit is uploaded and the VPS is not changed unless you type uppercase APPLY:\n$review"),
            PromptKind.EXACT_CONFIRMATION,
            placeholder = "APPLY",
            danger = true,
        ).trim()
        if (apply != "APPLY") throw CancellationException("install plan not applied")

        val publicIpResult = checked(handle, "ip=\$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); [ -n \"\$ip\" ] || ip=\$(hostname -I | awk '{print \$1}'); printf '%s\\n' \"\$ip\"", emit = false)
        val publicIp = publicIpResult.stdout.lines().map { it.trim() }.firstOrNull { runCatching { InetAddress.getByName(it) is Inet4Address }.getOrDefault(false) }
            ?: error(tr("无法确定 VPS 公网 IPv4", "Could not determine the VPS public IPv4"))
        when (plan.routeMode) {
            InstallRouteMode.GRAY -> waitForDns(plan.gray.domain, publicIp)
            InstallRouteMode.DUAL -> {
                waitForDns(plan.gray.domain, publicIp)
                waitForOrangeDns(plan.orange.domain, publicIp)
            }
            InstallRouteMode.ORANGE -> waitForOrangeDns(plan.orange.domain, publicIp)
            InstallRouteMode.KEEP -> Unit
        }

        if (needsUpload) {
            log(if (probe.installed) "TOOLKIT_UPGRADE ${probe.version.ifBlank { "missing" }} -> $VERSION" else "TOOLKIT_MISSING; installing v$VERSION")
            uploadToolkit(handle)
        } else {
            log("TOOLKIT_SAME_BUILD; upload and bootstrap skipped")
        }

        val oneRunName = "proxy-node-assistant-auto-input-${randomToken()}.env"
        val oneRunPath = "/tmp/$oneRunName"
        handle.upload(installAutoInput(plan).toByteArray(), oneRunName, "/tmp", "0600")
        try {
            val command = installEnvironment(handle, plan, oneRunPath) + " bash $REMOTE_ROOT/linux/00-auto-install-or-optimize.sh"
            checked(handle, command, interactive = true)
        } finally {
            runCatching { handle.exec("rm -f -- ${SshHandle.shellQuote(oneRunPath)}", root = true) }
        }
        reconcileRoute(handle, plan, publicIp)
        showHandoff(handle)
        if (plan.pruneAfterSuccess) {
            pruneBackups(handle, exactConfirmation = false)
        }
        return if (plan.openPanelOnSuccess) openPanel(handle) else false
    }

    private suspend fun detectExistingNode(handle: SshHandle): Boolean {
        val result = checked(
            handle,
	            "existing=0; if systemctl is-active --quiet x-ui 2>/dev/null || [ -x /usr/local/x-ui/x-ui ] || [ -s /etc/x-ui/x-ui.db ] || [ -s /etc/proxy-runbook/ss2022/service.env ] || [ -s /etc/text-node-assistant/ss2022/service.env ] || [ -s /etc/proxy-runbook/ss2022/server.json ] || [ -s /etc/text-node-assistant/ss2022/server.json ] || systemctl is-active --quiet tna-ss2022-112-trial.service 2>/dev/null; then existing=1; fi; printf 'TNA_EXISTING_NODE=%s\\n' \"\$existing\"",
            emit = false,
        )
        return result.stdout.lineSequence().any { it.trim() == "TNA_EXISTING_NODE=1" }
    }

    /**
     * Read only the existing SS2022 listener port so an upgrade does not
     * silently move a trial or custom listener to the formal port. The
     * command emits no credentials and an unavailable state is treated as
     * unknown; the user can still enter a port explicitly.
     */
	    private suspend fun detectExistingSs2022Port(handle: SshHandle): Int? {
	        // Match the desktop probe's precedence and legacy paths.  Emit one marker
	        // only, so a truncated/malformed probe cannot silently choose a stale port.
	        val command = """
	            port=""
	            for file in /etc/proxy-runbook/ss2022/service.env /etc/text-node-assistant/ss2022/service.env /etc/proxy-runbook/public.env /etc/text-node-assistant/public.env; do
	              [ -r "${'$'}file" ] || continue
	              value=""
	              case "${'$'}file" in
	                */ss2022/service.env)
	                  value="${'$'}(awk -F= '${'$'}1==\"PORT\" || ${'$'}1==\"SS2022_PORT\" || ${'$'}1==\"PNA_SS2022_PORT\" {gsub(/^[[:space:]]+|[[:space:]]+$/, \"\", ${'$'}2); print ${'$'}2; exit}' "${'$'}file" 2>/dev/null || true)"
	                  ;;
	                *)
	                  value="${'$'}(awk -F= '${'$'}1==\"SS2022_PORT\" || ${'$'}1==\"PNA_SS2022_PORT\" {gsub(/^[[:space:]]+|[[:space:]]+$/, \"\", ${'$'}2); print ${'$'}2; exit}' "${'$'}file" 2>/dev/null || true)"
	                  ;;
	              esac
	              case "${'$'}value" in
	                ''|*[!0-9]*) ;;
	                *)
	                  if [ "${'$'}value" -ge 1024 ] 2>/dev/null && [ "${'$'}value" -le 65535 ] 2>/dev/null; then
	                    port="${'$'}value"
	                    break
	                  fi
	                  ;;
	              esac
	            done
	            if [ -z "${'$'}port" ] && command -v jq >/dev/null 2>&1; then
	              for file in /etc/proxy-runbook/ss2022/server.json /etc/text-node-assistant/ss2022/server.json; do
	                [ -r "${'$'}file" ] || continue
	                value="${'$'}(jq -r '.inbounds[]? | select(.protocol == \"shadowsocks\") | select((.settings.method? // \"\") | startswith(\"2022-\")) | .port // empty' "${'$'}file" 2>/dev/null | head -n 1 || true)"
	                case "${'$'}value" in
	                  ''|*[!0-9]*) ;;
	                  *)
	                    if [ "${'$'}value" -ge 1024 ] 2>/dev/null && [ "${'$'}value" -le 65535 ] 2>/dev/null; then
	                      port="${'$'}value"
	                      break
	                    fi
	                    ;;
	                esac
	              done
	            fi
	            if [ -z "${'$'}port" ] && systemctl is-active --quiet tna-ss2022-112-trial.service 2>/dev/null; then
	              trial_port=""
	              if [ -r /run/tna-ss2022-112-trial.json ] && command -v jq >/dev/null 2>&1; then
	                trial_port="${'$'}(jq -r '.inbounds[0].port // empty' /run/tna-ss2022-112-trial.json 2>/dev/null || true)"
	              fi
	              case "${'$'}trial_port" in
	                ''|*[!0-9]*) ;;
	                *)
	                  if [ "${'$'}trial_port" -ge 1024 ] 2>/dev/null && [ "${'$'}trial_port" -le 65535 ] 2>/dev/null; then port="${'$'}trial_port"; fi
	                  ;;
	              esac
	            fi
	            printf 'SS2022_EXISTING_PORT=%s\n' "${'$'}{port:-0}"
	        """.trimIndent()
	        val result = handle.exec(command, root = true, log = { })
	        if (!result.ok) {
	            log("SS2022_EXISTING_PORT=UNKNOWN detail=remote_probe_exit_${result.exitCode}")
	            return null
	        }
        val markerLines = result.stdout.lineSequence()
            .map(String::trim)
            .filter { it.startsWith("SS2022_EXISTING_PORT=") }
            .toList()
        if (markerLines.size != 1) {
            log("SS2022_EXISTING_PORT=UNKNOWN detail=marker_count_${markerLines.size}")
            return null
        }
        val value = markerLines.single().substringAfter('=', missingDelimiterValue = "").toIntOrNull()
        if (value == null) {
            log("SS2022_EXISTING_PORT=UNKNOWN detail=marker_value_invalid")
            return null
        }
        return value.takeIf { it > 0 && Ss2022PortPolicy.valid(it) }
	    }

    private suspend fun collectInstallPlan(existingNode: Boolean, existingSs2022Port: Int? = null): AndroidInstallPlan {
        val routeMessage = if (existingNode) {
            tr(
                "必须选择：0=保持现有链路，1=仅灰云直连，2=仅橙云 CDN/XHTTP，3=双路。留空无效。",
                "Choose explicitly: 0=keep current route, 1=gray/direct only, 2=orange CDN/XHTTP only, 3=dual route. Blank is invalid.",
            )
        } else {
            tr(
                "必须选择：1=仅灰云直连，2=仅橙云 CDN/XHTTP，3=双路。全新节点不能选 0，留空无效。",
                "Choose explicitly: 1=gray/direct only, 2=orange CDN/XHTTP only, 3=dual route. A fresh node cannot use 0; blank is invalid.",
            )
        }
        val allowedRoutes = if (existingNode) setOf("0", "1", "2", "3") else setOf("1", "2", "3")
        val route = when (required(tr("选择链路模式", "Select route mode"), routeMessage) { it in allowedRoutes }) {
            "0" -> InstallRouteMode.KEEP
            "1" -> InstallRouteMode.GRAY
            "2" -> InstallRouteMode.ORANGE
            else -> InstallRouteMode.DUAL
        }

        val gray = if (route == InstallRouteMode.GRAY || route == InstallRouteMode.DUAL) {
            InstallRouteIdentity(
                domain = required(tr("灰云域名", "Gray/DNS-only hostname"), tr("输入 DNS-only 子域名；没有默认值。", "Enter the DNS-only hostname; there is no default.")) { Validation.validDomain(it) }.lowercase(),
                email = required(tr("灰云证书邮箱", "Gray-route certificate email"), tr("输入本人证书邮箱；不会写入设置或日志。", "Enter the certificate email; it is not written to settings or logs.")) { Validation.validEmail(it) },
            )
        } else InstallRouteIdentity()

        val orange = if (route == InstallRouteMode.ORANGE || route == InstallRouteMode.DUAL) {
            InstallRouteIdentity(
                domain = required(tr("橙云域名", "Orange/Proxied hostname"), tr("输入 Cloudflare Proxied 子域名；没有默认值。", "Enter the Cloudflare Proxied hostname; there is no default.")) { Validation.validDomain(it) }.lowercase(),
                email = required(tr("橙云源站证书邮箱", "Orange-route origin-certificate email"), tr("输入本人证书邮箱；不会写入设置或日志。", "Enter the origin-certificate email; it is not written to settings or logs.")) { Validation.validEmail(it) },
            )
        } else InstallRouteIdentity()

        val coverChoice = if (route == InstallRouteMode.KEEP) {
            "preserve"
        } else {
            val options = buildString {
                appendLine(tr("必须选择伪装模板：R=每次随机，A=按域名稳定选择，1—15=指定模板。", "Choose a cover template explicitly: R=random, A=stable per hostname, 1-15=exact template."))
                if (existingNode) appendLine(tr("0=保留当前伪装（仅已有节点）。", "0=preserve current cover (existing node only)."))
                append(COVER_TEMPLATE_CATALOG)
            }
            val raw = required(tr("选择伪装模板", "Select cover template"), options) { answer ->
                answer.isNotBlank() && ((existingNode && answer == "0") || Validation.normalizeTemplate(answer) != null)
            }
            if (raw == "0") "preserve" else requireNotNull(Validation.normalizeTemplate(raw))
        }

        val performanceAllowed = if (existingNode) setOf("0", "1", "2", "3", "4") else setOf("1", "2", "3", "4")
        val performance = when (required(
            tr("性能档位", "Performance profile"),
            tr(
                (if (existingNode) "必须选择：0=保留，" else "必须选择：") + "1=自动，2=低配，3=标准，4=高吞吐。留空无效。",
                (if (existingNode) "Choose explicitly: 0=preserve, " else "Choose explicitly: ") + "1=auto, 2=low, 3=standard, 4=high. Blank is invalid.",
            ),
        ) { it in performanceAllowed }) {
            "0" -> InstallPerformanceMode.PRESERVE
            "1" -> InstallPerformanceMode.AUTO
            "2" -> InstallPerformanceMode.LOW
            "3" -> InstallPerformanceMode.STANDARD
            else -> InstallPerformanceMode.HIGH
        }

        val warpAllowed = if (existingNode) setOf("0", "1") else setOf("1")
        val warp = when (required(
            tr("WARP 策略", "WARP policy"),
            tr(
                if (existingNode) "必须选择：0=保留当前状态，1=确保开启。留空无效。" else "全新节点必须输入 1=确保开启；留空无效。",
                if (existingNode) "Choose explicitly: 0=preserve current state, 1=ensure enabled. Blank is invalid." else "A fresh node requires 1=ensure enabled; blank is invalid.",
            ),
        ) { it in warpAllowed }) {
            "0" -> InstallWarpMode.PRESERVE
            else -> InstallWarpMode.ENSURE_ON
        }

        val preservedPort = existingSs2022Port?.takeIf { Ss2022PortPolicy.valid(it) }
        val ss2022Default = preservedPort ?: Ss2022PortPolicy.FORMAL_PORT
        val ss2022PortMessageZh = when {
            preservedPort == Ss2022PortPolicy.TRIAL_PORT -> "检测到已有 30443 trial 监听，默认保留；如需迁移到 v1 正式端口请输入 32443。"
            preservedPort != null -> "检测到已有 SS2022 监听 $preservedPort，默认保留；全新 v1 节点默认使用 32443。"
            existingNode -> "未能读取已有 SS2022 端口；默认使用 v1 正式端口 32443。若节点仍在使用 30443 trial，请明确输入 30443 以保留。"
            else -> "默认 32443（v1 正式端口）；30443 仅用于已有 trial/迁移兼容。"
        }
        val ss2022PortMessageEn = when {
            preservedPort == Ss2022PortPolicy.TRIAL_PORT -> "An existing 30443 trial listener was detected and will be preserved by default; enter 32443 explicitly to migrate to the v1 formal port."
            preservedPort != null -> "An existing SS2022 listener on $preservedPort was detected and will be preserved by default; fresh v1 nodes use 32443."
            existingNode -> "The existing SS2022 port could not be read; the v1 formal default is 32443. If this node still uses the 30443 trial, enter 30443 explicitly to preserve it."
            else -> "Default 32443 (the v1 formal port); 30443 is reserved for existing trial/migration compatibility."
        }
        val ss2022Port = required(
            tr("SS2022 TCP 端口", "SS2022 TCP port"),
            tr(
                "输入 1024—65535 的 TCP 端口；$ss2022PortMessageZh 不能与 443、24443、8443、40000 冲突。白名单稍后由操作 [19] 明确添加。",
                "Enter a TCP port from 1024-65535; $ss2022PortMessageEn It cannot conflict with 443, 24443, 8443, or 40000. Add the exact source later with action [19].",
            ),
            ss2022Default.toString(),
        ) { raw ->
            raw.toIntOrNull()?.let(Ss2022PortPolicy::valid) == true
        }.toInt()

        val prune = confirmYes(tr("成功后清理冗余备份，仅保留一份已验证的当前配置备份？", "After success, prune redundant backups and retain one verified current-config backup?"), false, allowNo = true)
        val openPanel = confirmYes(tr("成功后通过本机 SSH 隧道打开 3x-ui 面板？", "After success, open the 3x-ui panel through a localhost SSH tunnel?"), true, allowNo = true)
        return AndroidInstallPlan(route, coverChoice, performance, warp, gray, orange, prune, openPanel, ss2022Port)
    }

    private fun installAutoInput(plan: AndroidInstallPlan): String = buildString {
        appendLine("GRAY_DOMAIN_B64=${b64(plan.gray.domain)}")
        appendLine("GRAY_EMAIL_B64=${b64(plan.gray.email)}")
        appendLine("ORANGE_DOMAIN_B64=${b64(plan.orange.domain)}")
        appendLine("ORANGE_EMAIL_B64=${b64(plan.orange.email)}")
        appendLine("LANG=${if (language == Language.ZH) "zh" else "en"}")
    }

    private fun installEnvironment(handle: SshHandle, plan: AndroidInstallPlan, inputPath: String): String =
        plan.environmentValues(handle.target.user, if (language == Language.ZH) "zh" else "en", inputPath)
            .entries.joinToString(" ") { (key, value) -> "$key=${SshHandle.shellQuote(value)}" }

    private suspend fun reconcileRoute(handle: SshHandle, plan: AndroidInstallPlan, publicIp: String) {
        when (plan.routeMode) {
            InstallRouteMode.KEEP -> return
            InstallRouteMode.GRAY -> {
                val result = checked(handle, "bash $REMOTE_ROOT/linux/28-topology-reconcile.sh --to-gray ${SshHandle.shellQuote(plan.gray.domain)}", interactive = true)
                require("TNA_TOPOLOGY_RECONCILED=1" in result.stdout && "TOPOLOGY_MODE=gray" in result.stdout) { "gray topology reconciliation markers missing" }
            }
            InstallRouteMode.ORANGE, InstallRouteMode.DUAL -> reconcileOrangeRoute(handle, plan, publicIp)
        }
    }

    private suspend fun reconcileOrangeRoute(handle: SshHandle, plan: AndroidInstallPlan, publicIp: String) {
        val token = randomToken()
        val tempName = "proxy-node-assistant-cdn-route-$token.env"
        val tempPath = "/tmp/$tempName"
        // v1 uses a product-namespaced runtime directory. The reconciler also
        // accepts the legacy v0.9.x directory for upgrades, but a fresh client
        // must use only its own randomized root-only file.
        val preferredRuntimePath = "/root/.config/proxy-node-assistant/runtime-input/cdn-route-$token.env"
        val routeInput = buildString {
            appendLine("TNA_CDN_ROUTE_INPUT_VERSION=1")
            appendLine("ROUTE_MODE_B64=${b64(plan.routeMode.wireValue)}")
            appendLine("PUBLIC_IPV4_B64=${b64(publicIp)}")
            appendLine("ORANGE_DOMAIN_B64=${b64(plan.orange.domain)}")
            appendLine("ORANGE_EMAIL_B64=${b64(plan.orange.email)}")
            appendLine("GRAY_DOMAIN_B64=${b64(plan.gray.domain)}")
        }
        handle.upload(routeInput.toByteArray(), tempName, "/tmp", "0600")
        var completed = false
        try {
            checked(
                handle,
                "install -d -m 700 /root/.config/proxy-node-assistant/runtime-input; install -o root -g root -m 600 ${SshHandle.shellQuote(tempPath)} ${SshHandle.shellQuote(preferredRuntimePath)}; rm -f -- ${SshHandle.shellQuote(tempPath)}",
                emit = false,
            )
            val staged = checked(handle, "bash $REMOTE_ROOT/linux/28-topology-reconcile.sh --apply-input ${SshHandle.shellQuote(preferredRuntimePath)}", interactive = true)
            require("TNA_TOPOLOGY_STAGED=1" in staged.stdout) { "CDN topology staging marker missing" }
            val linkOutput = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh link ${SshHandle.shellQuote(plan.orange.domain)} 8443", emit = false).stdout
            val link = Regex("vless://[^\\s]+", RegexOption.IGNORE_CASE).find(linkOutput)?.value
                ?: error(tr("远端没有生成可测试的 CDN/XHTTP 链接", "The server did not produce a testable CDN/XHTTP link"))
            _state.update { it.copy(secretHandoff = link) }
            val answer = prompts.ask(
                tr("真实浏览验收", "Real browse verification"),
                tr(
                    "临时 CDN/XHTTP 链接已显示在秘密交接面板。请导入同机客户端并真实浏览；确认可用后输入大写 REAL BROWSE OK。输入其他内容将回滚本次橙云拓扑。\n$link",
                    "The staged CDN/XHTTP link is shown in the protected handoff panel. Import it into a client and really browse; only then type uppercase REAL BROWSE OK. Any other value rolls back this orange-route transaction.\n$link",
                ),
                PromptKind.EXACT_CONFIRMATION,
                placeholder = "REAL BROWSE OK",
                danger = true,
            ).trim()
            if (answer != "REAL BROWSE OK") throw CancellationException("CDN client verification declined")
            checked(handle, "bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh --confirm-client ${SshHandle.shellQuote(plan.orange.domain)}", interactive = true)
            val finalized = checked(handle, "bash $REMOTE_ROOT/linux/28-topology-reconcile.sh --finalize", interactive = true)
            require("TNA_TOPOLOGY_RECONCILED=1" in finalized.stdout && "TOPOLOGY_MODE=${plan.routeMode.wireValue}" in finalized.stdout) {
                "CDN topology finalization markers missing"
            }
            completed = true
        } finally {
            if (!completed) runCatching { handle.exec("bash $REMOTE_ROOT/linux/28-topology-reconcile.sh --rollback-pending", root = true) }
            runCatching { handle.exec("rm -f -- ${SshHandle.shellQuote(tempPath)} ${SshHandle.shellQuote(preferredRuntimePath)}", root = true) }
        }
    }

    private suspend fun waitForOrangeDns(domain: String, publicIp: String) {
        listOf(
            tr("[1/4] 确认 $domain 的 A 记录已开启 Cloudflare 橙云 Proxied。确认后按 Enter；输入 q 取消。", "[1/4] Confirm that the A record for $domain is Cloudflare Proxied. Press Enter to confirm or q to cancel."),
            tr("[2/4] 确认 SSL/TLS 为 Full (strict)，且 Universal SSL 已激活。确认后按 Enter；输入 q 取消。", "[2/4] Confirm SSL/TLS Full (strict) and active Universal SSL. Press Enter or q to cancel."),
            tr("[3/4] 客户端将使用 $domain:8443；免费计划无需且不应创建 443→8443 的全局 Origin Rule。确认后按 Enter；输入 q 取消。", "[3/4] The client will use $domain:8443. The free plan needs no global 443-to-8443 Origin Rule. Press Enter or q to cancel."),
            tr("[4/4] 确认该 hostname 绕过缓存，且没有 Access、Turnstile、质询、重定向或 Worker。确认后按 Enter；输入 q 取消。", "[4/4] Confirm cache bypass and no Access, Turnstile, challenge, redirect, or Worker on this hostname. Press Enter or q to cancel."),
        ).forEach { instruction ->
            val answer = prompts.ask(tr("Cloudflare 人工门禁", "Cloudflare manual gate"), instruction, PromptKind.TEXT)
            if (answer.trim().equals("q", true)) throw CancellationException("Cloudflare setup cancelled")
        }
        while (true) {
            val addresses = runCatching { InetAddress.getAllByName(domain).toList() }.getOrDefault(emptyList())
            if (addresses.isNotEmpty() && addresses.none { it.hostAddress == publicIp }) {
                log("ORANGE_DNS_READY; proxied hostname does not expose origin IPv4")
                return
            }
            val answer = prompts.ask(
                tr("橙云 DNS 尚未就绪", "Orange DNS not ready"),
                tr("公网解析仍为空或暴露源站 IPv4。检查橙云并等待传播；按 Enter 重试，输入 q 取消。", "Public DNS is empty or still exposes the origin IPv4. Check Proxied status and propagation; press Enter to retry or q to cancel."),
                PromptKind.TEXT,
            )
            if (answer.trim().equals("q", true)) throw CancellationException("Orange DNS verification cancelled")
        }
    }

    private fun b64(value: String): String = Base64.encodeToString(value.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)

    private fun randomToken(): String = newOneRunToken()

    private suspend fun uploadToolkit(handle: SshHandle) {
        log("Uploading embedded ProxyNodeAssistant toolkit v$VERSION...")
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
            root=''
            if [ -r $REMOTE_ROOT/TOOLKIT_VERSION ]; then
              root=$REMOTE_ROOT
            elif [ -r $LEGACY_TEXT_REMOTE_ROOT/TOOLKIT_VERSION ]; then
              root=$LEGACY_TEXT_REMOTE_ROOT
            elif [ -r $LEGACY_REMOTE_ROOT/TOOLKIT_VERSION ]; then
              root=$LEGACY_REMOTE_ROOT
            fi
            if [ -n "${'$'}root" ]; then
              version=${'$'}(head -n1 "${'$'}root/TOOLKIT_VERSION" | tr -d '\r')
              build=${'$'}(head -n1 "${'$'}root/TOOLKIT_BUILD_ID" 2>/dev/null | tr -d '\r' || true)
              revision=${'$'}(head -n1 "${'$'}root/TOOLKIT_BUILD_REVISION" 2>/dev/null | tr -d '\r' || true)
              complete=0
              test -x "${'$'}root/linux/00-auto-install-or-optimize.sh" && test -x "${'$'}root/linux/18-panel-metadata.sh" && test -x "${'$'}root/linux/22-dismantle-managed-node.sh" && test -x "${'$'}root/linux/23-ss2022-tcp.sh" && test -s "${'$'}root/templates/cover-sites/MANIFEST.tsv" && complete=1
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
            dirs=(/opt/proxy-node-assistant-v1.0.0 /opt/text-node-assistant-v0.9.5 /opt/proxy-runbook-v0.5 /opt/proxy-runbook-v0.6 /opt/proxy-runbook-v0.6.1 /opt/proxy-runbook-v0.6.2 /opt/proxy-runbook-v0.6.5 /opt/proxy-runbook-v0.6.6 /opt/proxy-runbook-v0.7.1 /opt/proxy-runbook-v0.7.4 /opt/proxy-runbook-v0.8.2 /opt/proxy-runbook-v0.8.4 /opt/proxy-runbook-v0.8.5 /opt/proxy-runbook-v0.8.6 /opt/proxy-runbook-v0.9.0)
            for target in "${'$'}{dirs[@]}"; do [ ! -e "${'$'}target" ] || { [ -d "${'$'}target" ] && [ ! -L "${'$'}target" ]; } || exit 61; done
            [ ! -e /opt/proxy-runbook-current ] || [ -L /opt/proxy-runbook-current ] || exit 62
            [ ! -e /opt/text-node-assistant-current ] || [ -L /opt/text-node-assistant-current ] || exit 63
            [ ! -e /opt/proxy-node-assistant-current ] || [ -L /opt/proxy-node-assistant-current ] || exit 64
            printf 'PROXY_RUNBOOK_UNINSTALL_BEGIN\n'
            rm -f /opt/text-node-assistant-current /opt/proxy-node-assistant-current /opt/proxy-runbook-current /usr/local/sbin/text-node /usr/local/sbin/proxy-node /tmp/text-node-assistant-toolkit-v*.tar.gz /tmp/proxy-node-assistant-toolkit-v*.tar.gz /tmp/proxy-runbook-toolkit-v*.tar.gz
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
        const val VERSION = "1.0.0"
        const val BUILD_ID = "20260901-v100-ss2022-r102"
        const val BUILD_REVISION = 102
        const val REMOTE_ROOT = "/opt/proxy-node-assistant-current"
        const val LEGACY_TEXT_REMOTE_ROOT = "/opt/text-node-assistant-current"
        const val LEGACY_REMOTE_ROOT = "/opt/proxy-runbook-current"
        const val INSTALL_ROOT = "/opt/proxy-node-assistant-v1.0.0"
        const val TOOLKIT_ASSET = "proxy-node-assistant-toolkit-v1.0.0.tgz"
        const val TOOLKIT_ARCHIVE = "proxy-node-assistant-toolkit-v1.0.0.tar.gz"
        val COVER_TEMPLATE_CATALOG = """
            1 atlas-journal   2 northstar-studio   3 cedar-stone
            4 field-lab       5 harbor-weather     6 local-library
            7 ember-cafe      8 trail-guide        9 signal-status
            10 mono-docs      11 analog-radio      12 city-calendar
            13 pixel-gallery  14 quiet-finance     15 signal-runner
        """.trimIndent()
    }
}
