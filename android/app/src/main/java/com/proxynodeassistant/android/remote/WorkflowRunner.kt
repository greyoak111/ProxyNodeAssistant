package com.proxynodeassistant.android.remote

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import com.proxynodeassistant.android.core.PromptBroker
import com.proxynodeassistant.android.core.Validation
import com.proxynodeassistant.android.data.HostKeyRepository
import com.proxynodeassistant.android.data.ManagedKeyRepository
import com.proxynodeassistant.android.data.StableNodeIdentityRepository
import com.proxynodeassistant.android.data.TargetRepository
import com.proxynodeassistant.android.model.ActionSpec
import com.proxynodeassistant.android.model.AuthMode
import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.Language
import com.proxynodeassistant.android.model.NodeTarget
import com.proxynodeassistant.android.model.PromptKind
import com.proxynodeassistant.android.model.RemoteResult
import com.proxynodeassistant.android.model.RunStatus
import com.proxynodeassistant.android.model.StableNodeIdentity
import com.proxynodeassistant.android.model.ToolkitProbe
import com.proxynodeassistant.android.model.WorkflowUiState
import com.proxynodeassistant.android.service.TunnelRegistry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.security.MessageDigest
import java.util.Locale

class WorkflowRunner(
    private val context: Context,
    private val ssh: SshEngine,
    private val managedKeys: ManagedKeyRepository,
    private val targets: TargetRepository,
    private val prompts: PromptBroker,
    private val hostKeys: HostKeyRepository? = null,
    private val stableNodes: StableNodeIdentityRepository? = null,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow(WorkflowUiState())
    val state: StateFlow<WorkflowUiState> = _state.asStateFlow()
    private var job: Job? = null
    @Volatile private var activeHandle: SshHandle? = null
    @Volatile private var language: Language = Language.ZH
    /** Presence bits from the current install run; never contains secrets. */
    @Volatile private var credentialReadiness: CredentialReadiness = CredentialReadiness.UNKNOWN

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
                // IP rebind is deliberately a pre-connect flow.  It must use the
                // old endpoint's pinned host key and managed key, then connect to
                // the proposed endpoint under a fail-closed identity check.
                if (action.code.equals("23", true)) {
                    handle = rebindPublicIp(target)
                    activeHandle = handle
                    _state.update { it.copy(status = RunStatus.RUNNING) }
                    _state.update { it.copy(status = RunStatus.SUCCEEDED) }
                    return@launch
                }
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
                // Persist the VPS stable identity opportunistically for future
                // safe IP rebinds.  Failure is non-fatal for legacy nodes that
                // predate the identity script; it never creates a new identity.
                if (action.code != "23") syncStableNodeIdentity(handle)
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
        "24" -> { ensureToolkit(handle); manageSS2022AllowlistMenu(handle); false }
        "20" -> { ensureToolkit(handle); securityEvents(handle); false }
        "22" -> { ensureToolkit(handle); cdnXhttpControl(handle); false }
        "23" -> error("IP rebind must run before opening the old endpoint session")
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
            # Read both product and legacy SS2022 metadata.  The legacy file
            # is a compatibility source only; it is never sourced as shell
            # code, so arbitrary values cannot execute during diagnostics.
            cat /etc/text-node-assistant/ss2022/service.env 2>/dev/null || true
            cat /etc/proxy-runbook/ss2022/service.env 2>/dev/null || true
            # Select one validated port for the probe.  Keep the same
            # precedence as the upgrade planner (managed service metadata,
            # public compatibility metadata, then old JSON/trial state) and
            # emit a single marker last so stale files cannot override it.
            ss_port=""
            for file in /etc/proxy-runbook/ss2022/service.env /etc/text-node-assistant/ss2022/service.env /etc/proxy-runbook/public.env /etc/text-node-assistant/public.env; do
              [ -r "${'$'}file" ] || continue
              case "${'$'}file" in
                */ss2022/service.env)
                  value="${'$'}(awk -F= '${'$'}1=="PORT" || ${'$'}1=="SS2022_PORT" || ${'$'}1=="PNA_SS2022_PORT" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", ${'$'}2); print ${'$'}2; exit}' "${'$'}file" 2>/dev/null || true)"
                  ;;
                *)
                  value="${'$'}(awk -F= '${'$'}1=="SS2022_PORT" || ${'$'}1=="PNA_SS2022_PORT" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", ${'$'}2); print ${'$'}2; exit}' "${'$'}file" 2>/dev/null || true)"
                  ;;
              esac
              case "${'$'}value" in
                ''|*[!0-9]*) ;;
                *) if [ "${'$'}value" -ge 1024 ] 2>/dev/null && [ "${'$'}value" -le 65535 ] 2>/dev/null; then ss_port="${'$'}value"; break; fi ;;
              esac
            done
            if [ -z "${'$'}ss_port" ] && command -v jq >/dev/null 2>&1; then
              for file in /etc/proxy-runbook/ss2022/server.json /etc/text-node-assistant/ss2022/server.json /etc/proxy-runbook/server.json /etc/text-node-assistant/server.json /etc/proxy-runbook/xray/server.json /etc/text-node-assistant/xray/server.json; do
                [ -r "${'$'}file" ] || continue
                value="${'$'}(jq -r '.inbounds[]? | select(.protocol == "shadowsocks") | select((.settings.method? // "") | startswith("2022-")) | .port // empty' "${'$'}file" 2>/dev/null | head -n 1 || true)"
                case "${'$'}value" in
                  ''|*[!0-9]*) ;;
                  *) if [ "${'$'}value" -ge 1024 ] 2>/dev/null && [ "${'$'}value" -le 65535 ] 2>/dev/null; then ss_port="${'$'}value"; break; fi ;;
                esac
              done
            fi
            if [ -z "${'$'}ss_port" ] && systemctl is-active --quiet tna-ss2022-112-trial.service 2>/dev/null; then
              trial_port=""
              if [ -r /run/tna-ss2022-112-trial.json ] && command -v jq >/dev/null 2>&1; then
                trial_port="${'$'}(jq -r '.inbounds[0].port // empty' /run/tna-ss2022-112-trial.json 2>/dev/null || true)"
              fi
              case "${'$'}trial_port" in
                ''|*[!0-9]*) ;;
                *) if [ "${'$'}trial_port" -ge 1024 ] 2>/dev/null && [ "${'$'}trial_port" -le 65535 ] 2>/dev/null; then ss_port="${'$'}trial_port"; fi ;;
              esac
            fi
            [ -n "${'$'}ss_port" ] && printf 'SS2022_PORT=%s\n' "${'$'}ss_port"
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

    private data class Ss2022AllowlistSnapshot(
        val entries: List<String>,
        val status: Map<String, String>,
    )

    /**
     * Resolve the active SS2022 helper at execution time.  In-place upgrades
     * can briefly expose only one of the canonical or legacy compatibility
     * symlinks; embedding REMOTE_ROOT directly in every action made the
     * allowlist manager fail even though the toolkit was present elsewhere.
     */
    private fun ss2022Command(vararg args: String): String = buildString {
        append("root=").append(SshHandle.shellQuote(REMOTE_ROOT)).append("; ")
        append("[ -x \"").append('$').append("root/linux/23-ss2022-tcp.sh\" ] || root=")
            .append(SshHandle.shellQuote(LEGACY_TEXT_REMOTE_ROOT)).append("; ")
        append("[ -x \"").append('$').append("root/linux/23-ss2022-tcp.sh\" ] || root=")
            .append(SshHandle.shellQuote(LEGACY_REMOTE_ROOT)).append("; ")
        append("[ -x \"").append('$').append("root/linux/23-ss2022-tcp.sh\" ] || { printf 'PNA_SS2022_ERROR=SCRIPT_MISSING\\n' >&2; exit 62; }; ")
        append("bash \"").append('$').append("root/linux/23-ss2022-tcp.sh\"")
        args.forEach { append(' ').append(SshHandle.shellQuote(it)) }
    }

    /**
     * Read the managed SS2022 allowlist without treating the remote output as
     * shell text.  The script's list protocol emits one SOURCE= line per
     * exact address; normalize every value again before displaying or using it
     * in a follow-up command.
     */
    private suspend fun readSS2022Allowlist(handle: SshHandle): Ss2022AllowlistSnapshot {
        // v1's snapshot mode combines a healthy service check with a strict
        // allowlist read.  It refuses an inactive listener, missing firewall,
        // malformed source, or duplicate entry instead of presenting a
        // misleading empty list to the operator.
        val snapshot = handle.exec(
            ss2022Command("snapshot"),
            root = true,
            log = { },
        )
        check(snapshot.ok) {
            val detail = (snapshot.stderr.ifBlank { snapshot.stdout }).trim().takeLast(800)
            "SS2022 allowlist snapshot failed (exit ${snapshot.exitCode}): $detail"
        }
        val statusValues = runCatching { ProtocolParsers.kv(snapshot.stdout) }.getOrDefault(emptyMap())
        val summary = listOf("PRESENT", "ACTIVE", "LISTENER", "FIREWALL", "PORT", "ALLOWLIST_COUNT")
            .mapNotNull { key -> statusValues[key]?.let { "$key=$it" } }
            .joinToString(" ")
        if (summary.isNotBlank()) log("SS2022_STATUS $summary")
        val rawSources = snapshot.stdout.lineSequence()
            .map(String::trim)
            .filter { it.startsWith("SOURCE=") }
            .map { it.removePrefix("SOURCE=").trim() }
            .filter { it.isNotBlank() }
            .toList()
        val normalized = rawSources.mapNotNull { AndroidNetworkProbes.normalizePublicIpv4(it) }
        val invalidCount = rawSources.count { AndroidNetworkProbes.normalizePublicIpv4(it) == null }
        if (invalidCount > 0) log("SS2022_ALLOWLIST_INVALID_LINES=$invalidCount (ignored)")
        val entries = normalized.distinct().sorted()
        log("SS2022_ALLOWLIST_BEGIN")
        if (entries.isEmpty()) {
            log("SS2022_ALLOWLIST_EMPTY=1")
        } else {
            entries.forEach { log("SS2022_ALLOWLIST_SOURCE=$it") }
        }
        log("SS2022_ALLOWLIST_COUNT=${entries.size}")
        log("SS2022_ALLOWLIST_END")
        return Ss2022AllowlistSnapshot(entries, statusValues)
    }

    /**
     * Action [24] is an explicit management console.  It starts by showing
     * the current list, then allows repeated read/add/remove operations over
     * the same authenticated SSH session.  Every mutation is separately
     * confirmed and only exact global IPv4 addresses are accepted.
     */
    private suspend fun manageSS2022AllowlistMenu(handle: SshHandle) {
        var snapshot = readSS2022Allowlist(handle)
        val options = listOf(
            tr("VIEW｜查看当前列表", "VIEW CURRENT LIST"),
            tr("ADD｜添加精确 IPv4", "ADD EXACT IPv4"),
            tr("REMOVE｜删除精确 IPv4", "REMOVE EXACT IPv4"),
            tr("CANCEL｜退出管理", "CANCEL MANAGEMENT"),
        )
        while (true) {
            val choice = prompts.ask(
                tr("SS2022 白名单管理", "SS2022 allowlist management"),
                tr(
                    "当前列表已显示。请选择只读查看、添加或删除；仅接受公网 IPv4，不接受 CIDR/网段。",
                    "The current list is shown above. Choose read, add, or remove; only public IPv4 addresses are accepted, never CIDR ranges.",
                ),
                PromptKind.CHOICE,
                options = options,
            )
            when {
                choice.startsWith("VIEW", true) || choice.contains("查看") -> {
                    snapshot = readSS2022Allowlist(handle)
                }
                choice.startsWith("ADD", true) || choice.contains("添加") -> {
                    val source = promptSS2022Source(
                        tr("添加 SS2022 白名单地址", "Add SS2022 allowlist address"),
                        tr("输入一个精确公网 IPv4；不会接受网段或 CIDR。", "Enter one exact public IPv4; ranges and CIDR are rejected."),
                    )
                    if (source == null) {
                        log("SS2022_ALLOWLIST=ADD_CANCELLED")
                        continue
                    }
                    if (source in snapshot.entries) {
                        log("SS2022_ALLOWLIST=ALREADY_PRESENT source=$source")
                        continue
                    }
                    if (!confirmYes(
                            tr("确认添加白名单地址 $source？", "Confirm adding allowlist address $source?"),
                            defaultYes = false,
                            allowNo = true,
                        )) {
                        log("SS2022_ALLOWLIST=UNCHANGED")
                        continue
                    }
                    val result = checked(handle, ss2022Command("allow", source))
                    check("PNA_SS2022_ALLOW_ADDED=$source" in result.stdout) { "SS2022 allowlist add marker missing" }
                    log("SS2022_ALLOWLIST=ADDED source=$source")
                    snapshot = readSS2022Allowlist(handle)
                }
                choice.startsWith("REMOVE", true) || choice.contains("删除") -> {
                    val source = promptSS2022Source(
                        tr("删除 SS2022 白名单地址", "Remove SS2022 allowlist address"),
                        tr("输入当前列表中的精确公网 IPv4；删除后该地址将立即失去 SS2022 访问。", "Enter an exact public IPv4 from the current list; removal immediately blocks SS2022 access from that address."),
                    )
                    if (source == null) {
                        log("SS2022_ALLOWLIST=REMOVE_CANCELLED")
                        continue
                    }
                    if (source !in snapshot.entries) {
                        log("SS2022_ALLOWLIST=NOT_PRESENT source=$source")
                        continue
                    }
                    if (!confirmYes(
                            tr("确认删除 $source？这可能使该来源无法再连接 SS2022。", "Confirm removing $source? This may prevent that source from connecting to SS2022."),
                            defaultYes = false,
                            allowNo = true,
                        )) {
                        log("SS2022_ALLOWLIST=UNCHANGED")
                        continue
                    }
                    val result = checked(handle, ss2022Command("remove", source))
                    check("PNA_SS2022_ALLOW_REMOVED=$source" in result.stdout) { "SS2022 allowlist remove marker missing" }
                    log("SS2022_ALLOWLIST=REMOVED source=$source")
                    snapshot = readSS2022Allowlist(handle)
                }
                else -> {
                    log("SS2022_ALLOWLIST=UNCHANGED")
                    return
                }
            }
        }
    }

    private suspend fun promptSS2022Source(title: String, message: String): String? {
        while (true) {
            val promptMessage = "$message\n${tr("留空、输入 q 或 0 可取消。", "Leave blank, type q, or type 0 to cancel.")}"
            val raw = prompts.ask(
                title,
                promptMessage,
                PromptKind.TEXT,
                placeholder = "1.2.3.4",
            ).trim()
            if (raw.isBlank() || raw.equals("q", true) || raw == "0" || raw.equals("cancel", true) || raw == "取消") return null
            AndroidNetworkProbes.normalizePublicIpv4(raw)?.let { return it }
            log("INPUT_REJECTED: $title (exact global IPv4 required)")
        }
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
        val status = handle.exec(ss2022Command("status"), root = true, log = ::log)
        check(status.ok) { "SS2022 status failed (exit ${status.exitCode})" }
        val statusValues = ProtocolParsers.kv(status.stdout)
        check(statusValues["PRESENT"] == "1" && statusValues["ACTIVE"] == "1" && statusValues["LISTENER"] == "1" && statusValues["FIREWALL"] == "1") {
            "SS2022 service is not ready (PRESENT=${statusValues["PRESENT"] ?: "?"}, ACTIVE=${statusValues["ACTIVE"] ?: "?"}, LISTENER=${statusValues["LISTENER"] ?: "?"}, FIREWALL=${statusValues["FIREWALL"] ?: "?"})"
        }
        val list = handle.exec(ss2022Command("list"), root = true, log = ::log)
        check(list.ok) { "SS2022 allowlist listing failed (exit ${list.exitCode})" }
        val statusOutput = status.stdout + "\n" + list.stdout
        val statusSummary = statusOutput.lines().filter { it.contains("PNA_SS2022_") || it.startsWith("PORT=") || it.startsWith("ALLOWLIST_COUNT=") || it.startsWith("SOURCE=") }.joinToString(" ")
        if (statusSummary.isNotBlank()) log("SS2022_STATUS $statusSummary")
		log(tr(
		    "[INFO] 本项只负责识别本机 IP 并一键添加当前来源；完整列表与自由增删请返回控制面选择并列的 OP:24。",
		    "[INFO] This action only detects the local IP and offers a one-shot add; return to the control plane and choose parallel OP:24 for the full list and freely add/remove.",
		))

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

        val update = checked(handle, ss2022Command("allow", observed))
        check("PNA_SS2022_ALLOW_ADDED=$observed" in update.stdout) { "SS2022 allowlist update marker missing" }
        val verifiedStatus = checked(handle, ss2022Command("status"), emit = false)
        val verifiedList = checked(handle, ss2022Command("list"), emit = false)
        log("SS2022_ALLOWLIST=UPDATED source=$observed")
        val verifiedOutput = verifiedStatus.stdout + "\n" + verifiedList.stdout
        verifiedOutput.lines().filter { it.startsWith("PRESENT=") || it.startsWith("ACTIVE=") || it.startsWith("LISTENER=") || it.startsWith("FIREWALL=") || it.startsWith("PORT=") || it.startsWith("ALLOWLIST_COUNT=") || it.startsWith("SOURCE=") }.forEach { log("  $it") }

        val port = ProtocolParsers.kv(verifiedOutput)["PORT"]?.toIntOrNull()?.takeIf { Ss2022PortPolicy.valid(it) }
            ?: Ss2022PortPolicy.FORMAL_PORT
        logRouteProbe(AndroidNetworkProbes.tcpProbe("SS2022", handle.target.host, port))
    }

    private suspend fun deploy(handle: SshHandle): Boolean {
        // Never carry a previous target's readiness result into a new run.
        // This state contains presence bits only, but a stale complete bit could
        // otherwise make an empty policy answer preserve the wrong node.
        credentialReadiness = CredentialReadiness.UNKNOWN
        val probe = probe(handle)
        val comparison = if (probe.installed) ProtocolParsers.compareVersions(probe.version, VERSION) else -1
        var toolkitOnlyUpdate = false
        var toolkitOnlyReason = ""
        val needsUpload = when {
            !probe.installed -> true
            comparison > 0 -> error(tr("远端工具包 v${probe.version} 更新，请改用同版或更新的 Android 客户端", "Remote toolkit v${probe.version} is newer; use a matching or newer Android client"))
            // An equal revision with a blank or divergent build ID is
            // ambiguous metadata, not a safe package refresh.  Refuse it
            // before collecting the full install plan; only a clearly older
            // revision (or an explicitly allowed incomplete upload) can use
            // the bounded toolkit-only path below.
            comparison == 0 && (probe.buildRevision > BUILD_REVISION || (probe.buildRevision == BUILD_REVISION && probe.buildId != BUILD_ID)) -> error(tr("远端 v$VERSION 构建更新、不同或元数据不完整，已拒绝覆盖；请使用匹配客户端", "Remote v$VERSION build is newer, different, or has incomplete metadata; overwrite refused. Use a matching client"))
            comparison == 0 && sameVersionToolkitOnlyUpdateRequired(probe) -> {
                toolkitOnlyUpdate = true
                toolkitOnlyReason = if (probe.complete) "older same-version build" else "incomplete same-version toolkit"
                log("TOOLKIT_ONLY_UPDATE_REQUIRED reason=$toolkitOnlyReason")
                true
            }
            comparison == 0 && !probe.complete -> error(tr("远端 v$VERSION 工具包不完整且构建信息不兼容；请换用匹配的 Android 客户端", "Remote v$VERSION is incomplete with incompatible build metadata; use a matching Android client"))
            comparison == 0 && probe.buildRevision == BUILD_REVISION && probe.buildId == BUILD_ID -> false
            else -> true
        }

        // A same-version refresh is a bounded package operation.  Do not ask
        // for routes, credentials, panel settings, or DNS and do not invoke
        // the full installer; a stale panel verifier in an older toolkit must
        // not be able to block an otherwise safe embedded-package repair.
        if (toolkitOnlyUpdate) {
            updateToolkitOnly(handle, toolkitOnlyReason)
            return false
        }

        // Recover an interrupted convergence before collecting a new plan.  The
        // transaction helper is present in v1 and in the compatible v0.9.x
        // toolkit; a legacy endpoint without it is reported explicitly and is
        // never silently treated as an active transaction.
        recoverInterruptedInstallTransaction(handle)

        val existingNode = detectExistingNode(handle)
        val existingSs2022Port = if (existingNode) detectExistingSs2022Port(handle) else null
        existingSs2022Port?.let { log("SS2022_EXISTING_PORT=$it (upgrade default preserves the existing listener)") }
        if (existingNode) {
            credentialReadiness = detectCredentialReadiness(handle)
            if (credentialReadiness.isComplete) {
                log(tr(
                    "CREDENTIAL_HANDOFF_READY=1（仅存在性；凭据策略选保留即可，远端会再次验证）",
                    "CREDENTIAL_HANDOFF_READY=1 (presence only; choose preserve and the remote installer will verify again)",
                ))
            } else {
                log(tr(
                    "CREDENTIAL_HANDOFF_READY=0（${credentialReadiness.summary()}；未读取密码）",
                    "CREDENTIAL_HANDOFF_READY=0 (${credentialReadiness.summary()}; passwords were not read)",
                ))
            }
        }
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
                guideCloudflareCertificatePrerequisites(plan.orange.domain)
                waitForDns(plan.gray.domain, publicIp)
                waitForOrangeDns(plan.orange.domain, publicIp)
            }
            InstallRouteMode.ORANGE -> {
                guideCloudflareCertificatePrerequisites(plan.orange.domain)
                waitForOrangeDns(plan.orange.domain, publicIp)
            }
            InstallRouteMode.KEEP -> Unit
        }

        // A fresh VPS has no transaction helper until the embedded toolkit is
        // uploaded.  Uploading is still guarded by APPLY above; once the exact
        // toolkit is present we capture the native baseline and start the
        // atomic convergence transaction before touching services/config.
        if (needsUpload) {
            log(if (probe.installed) "TOOLKIT_UPGRADE ${probe.version.ifBlank { "missing" }} -> $VERSION" else "TOOLKIT_MISSING; installing v$VERSION")
            uploadToolkit(handle)
        } else {
            log("TOOLKIT_SAME_BUILD; upload and bootstrap skipped")
        }
        captureOriginalBaseline(handle)
        ensureInstallNodeIdentity(handle)
        val transactionId = beginInstallTransaction(handle)
        var transactionActive = true
        try {
            // Write the auto-input through the already authenticated root
            // session so a non-root SSH account cannot leave a user-owned
            // credential file that the runbook would reject.  The payload is
            // base64 on stdin, never part of the command line or log stream.
            val oneRunPath = writeOneRunInput(handle, installAutoInput(plan), "auto-input")
            try {
                val command = installEnvironment(handle, plan, oneRunPath) + " bash $REMOTE_ROOT/linux/00-auto-install-or-optimize.sh"
                checked(handle, command, interactive = true)
            } finally {
                // Cancellation must not skip deletion of the root-only input;
                // the file can contain custom passwords for both rotations.
                withContext(NonCancellable) { removeOneRunInput(handle, oneRunPath) }
            }
            reconcileRoute(handle, plan, publicIp)
            showHandoff(handle)
            commitInstallTransaction(handle, transactionId)
            transactionActive = false
        } finally {
            if (transactionActive) {
                runCatching { rollbackInstallTransaction(handle, transactionId) }
                    .onFailure { log("INSTALL_TRANSACTION_ROLLBACK_FAILED: ${safeError(it)}") }
            }
        }
        if (plan.pruneAfterSuccess) {
            pruneBackups(handle, exactConfirmation = false)
        }
        return if (plan.openPanelOnSuccess) openPanel(handle) else false
    }

    /**
     * Restore a previous unfinished install before planning a new one.  The
     * parser intentionally accepts only the explicit status markers emitted by
     * 28a; malformed/unknown states stop the workflow rather than risking a
     * second mutation on top of an uncertain snapshot.
     */
    private suspend fun recoverInterruptedInstallTransaction(handle: SshHandle) {
        val command = """
            set -u
            root='$REMOTE_ROOT'
            [ -x \"${'$'}root/linux/28a-install-transaction.sh\" ] || root='$LEGACY_TEXT_REMOTE_ROOT'
            [ -x \"${'$'}root/linux/28a-install-transaction.sh\" ] || root='$LEGACY_REMOTE_ROOT'
            if [ -x \"${'$'}root/linux/28a-install-transaction.sh\" ]; then
              bash \"${'$'}root/linux/28a-install-transaction.sh\" status
            else
              printf 'TNA_INSTALL_TRANSACTION_STATUS_BEGIN\nTRANSACTION_STATUS=NONE\nTNA_INSTALL_TRANSACTION_STATUS_END\n'
            fi
        """.trimIndent()
        val statusOutput = checked(handle, command, emit = false).stdout
        val statusPayload = ProtocolParsers.markedBlockCurrentOrLegacy(
            statusOutput,
            "TNA_INSTALL_TRANSACTION_STATUS_BEGIN",
            "TNA_INSTALL_TRANSACTION_STATUS_END",
            "TNA_INSTALL_TRANSACTION_STATUS_BEGIN",
            "TNA_INSTALL_TRANSACTION_STATUS_END",
        )
        val status = ProtocolParsers.kv(statusPayload)
        when (status["TRANSACTION_STATUS"]) {
            null, "NONE" -> Unit
            "PREPARING", "ACTIVE", "ROLLING_BACK", "ROLLBACK_FAILED" -> {
                log(tr("检测到上次未提交施工，先恢复事务快照，禁止在半成品上叠加。", "A prior install was not committed; restore its transaction snapshot before planning another one."))
                val rollback = checked(handle, transactionCommand("rollback"), emit = false)
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
        val command = """
            set -u
            root='$REMOTE_ROOT'
            [ -x \"${'$'}root/linux/22-dismantle-managed-node.sh\" ] || root='$LEGACY_TEXT_REMOTE_ROOT'
            [ -x \"${'$'}root/linux/22-dismantle-managed-node.sh\" ] || root='$LEGACY_REMOTE_ROOT'
            [ -x \"${'$'}root/linux/22-dismantle-managed-node.sh\" ] || { echo TNA_BASELINE_CAPTURE=UNAVAILABLE >&2; exit 63; }
            bash \"${'$'}root/linux/22-dismantle-managed-node.sh\" --capture-baseline
        """.trimIndent()
        val result = checked(handle, command, emit = false)
        require(
            listOf("ORIGINAL_BASELINE_CAPTURED_EXACT", "ORIGINAL_BASELINE_ALREADY_CAPTURED", "ORIGINAL_BASELINE_LEGACY_UNCERTAIN").any { it in result.stdout },
        ) { "Pre-construction baseline capture returned no accepted evidence" }
        log(tr("[GOOD] 原生基线已捕获或复核，后续施工可回滚。", "[GOOD] Native baseline captured or verified; subsequent construction can be rolled back."))
    }

    /**
     * Ensure the VPS has a stable, machine-bound identity before convergence.
     * This is endpoint continuity metadata (machine-id/host-key), not a
     * per-client enrollment check. Existing identities are only read and
     * persisted locally; a missing identity is initialized by the signed
     * toolkit script with its own atomic state file.
     */
    private suspend fun ensureInstallNodeIdentity(handle: SshHandle) {
        val repository = stableNodes ?: return
        runCatching { readStableNodeIdentity(handle) }.onSuccess {
            repository.put(it)
            log("NODE_IDENTITY_EXISTING_VERIFIED")
            return
        }
        val command = """
            set -u
            root='$REMOTE_ROOT'
            [ -x \"${'$'}root/linux/23-node-identity.sh\" ] || root='$LEGACY_TEXT_REMOTE_ROOT'
            [ -x \"${'$'}root/linux/23-node-identity.sh\" ] || root='$LEGACY_REMOTE_ROOT'
            [ -x \"${'$'}root/linux/23-node-identity.sh\" ] || { echo TNA_NODE_IDENTITY_ERROR=SCRIPT_MISSING >&2; exit 62; }
            bash \"${'$'}root/linux/23-node-identity.sh\" --init
        """.trimIndent()
        val initialized = checked(handle, command, emit = false)
        val identity = ProtocolParsers.stableNodeIdentity(initialized.stdout, handle.target.id)
        repository.put(identity)
        log("NODE_IDENTITY_INITIALIZED_AND_VERIFIED")
    }

    private suspend fun beginInstallTransaction(handle: SshHandle): String {
        val result = checked(handle, transactionCommand("begin standalone 0"), emit = false)
        require("TNA_INSTALL_TRANSACTION_BEGAN=1" in result.stdout) { "install transaction begin marker missing" }
        return ProtocolParsers.kv(result.stdout)["TRANSACTION_ID"].orEmpty().also {
            require(Regex("^tna-install-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$").matches(it)) { "invalid install transaction id" }
        }
    }

    private suspend fun rollbackInstallTransaction(handle: SshHandle, transactionId: String) {
        val status = ProtocolParsers.kv(checked(handle, transactionCommand("status"), emit = false).stdout)
        if (status["TRANSACTION_STATUS"] == "NONE") return
        require(status["TRANSACTION_ID"] == transactionId) { "Refusing to roll back another install transaction" }
        val result = checked(handle, transactionCommand("rollback"), emit = false)
        require("TNA_INSTALL_TRANSACTION_ROLLED_BACK=1" in result.stdout) { "install transaction rollback marker missing" }
        log(tr("[GOOD] 未提交施工已恢复到事务前状态。", "[GOOD] Uncommitted construction was restored to its pre-transaction state."))
    }

    private suspend fun commitInstallTransaction(handle: SshHandle, transactionId: String) {
        val status = ProtocolParsers.kv(checked(handle, transactionCommand("status"), emit = false).stdout)
        require(status["TRANSACTION_STATUS"] == "ACTIVE" && status["TRANSACTION_ID"] == transactionId) {
            "install transaction status changed before commit"
        }
        val result = checked(handle, transactionCommand("commit"), emit = false)
        require("TNA_INSTALL_TRANSACTION_COMMITTED=1" in result.stdout) { "install transaction commit marker missing" }
        log(tr("[GOOD] 菜单 [1] 的远端阶段已原子提交。", "[GOOD] The remote stages of action 1 were committed atomically."))
    }

    /** Select a product root without exposing credentials or silently running a legacy script. */
    private fun transactionCommand(arguments: String): String = """
        root='$REMOTE_ROOT'
        [ -x \"${'$'}root/linux/28a-install-transaction.sh\" ] || root='$LEGACY_TEXT_REMOTE_ROOT'
        [ -x \"${'$'}root/linux/28a-install-transaction.sh\" ] || root='$LEGACY_REMOTE_ROOT'
        [ -x \"${'$'}root/linux/28a-install-transaction.sh\" ] || { echo TNA_INSTALL_TRANSACTION_ERROR=SCRIPT_MISSING >&2; exit 64; }
        bash \"${'$'}root/linux/28a-install-transaction.sh\" $arguments
    """.trimIndent()

    /**
     * Build a read-only, secret-free scan for the install form.  v0.9.0 did
     * not have the protected credential-store helpers, so this intentionally
     * scans both generations of handoff files with a small awk predicate
     * instead of requiring a particular toolkit version.  The predicate only
     * returns an exit status; no account or password value is written to
     * stdout, stderr, or the Android log.
     */
    private fun credentialReadinessCommand(): String = """
        set -u
        printf '%s\n' '${ProtocolParsers.CREDENTIAL_READINESS_BEGIN}'
        candidate_files() {
          for dir in /root/.config/proxy-runbook /root/.config/text-node-assistant /root/.config/proxy-node-assistant; do
            for file in "${'$'}dir/CURRENT-LOGIN-CREDENTIALS.env" "${'$'}dir/HANDOFF-SECRETS.txt"; do
              [ -r "${'$'}file" ] && printf '%s\n' "${'$'}file"
            done
            if [ -d "${'$'}dir/handoff-archive" ] && command -v find >/dev/null 2>&1; then
              find "${'$'}dir/handoff-archive" -maxdepth 1 -type f -name 'HANDOFF-*.txt' -print 2>/dev/null || true
            fi
          done
        }
        value_present() {
          local wanted="${'$'}1" file
          while IFS= read -r file; do
            [ -n "${'$'}file" ] || continue
            if awk -v wanted="${'$'}wanted" '
              function matches(name) {
                if (wanted == "VPS_LOGIN_USER")
                  return name == "VPS_LOGIN_USER" || name == "VPS_ACCOUNT" || name == "FORM_VPS_ACCOUNT"
                if (wanted == "VPS_LOGIN_PASSWORD")
                  return name == "VPS_LOGIN_PASSWORD" || name == "VPS_PASSWORD" || name == "FORM_VPS_PASSWORD"
                if (wanted == "PANEL_USERNAME")
                  return name == "PANEL_USERNAME" || name == "PANEL_ACCOUNT" || name == "XUI_USERNAME" || name == "FORM_PANEL_ACCOUNT"
                if (wanted == "PANEL_PASSWORD")
                  return name == "PANEL_PASSWORD" || name == "XUI_PASSWORD" || name == "FORM_PANEL_PASSWORD"
                return name == wanted
              }
              {
                separator = index(${'$'}0, "=")
                if (separator <= 0) next
                name = substr(${'$'}0, 1, separator - 1)
                value = substr(${'$'}0, separator + 1)
                gsub(/^[[:space:]]+|[[:space:]]+${'$'}/, "", name)
                gsub(/^[[:space:]]+|[[:space:]]+${'$'}/, "", value)
                # Keep the shell-side readiness matcher aligned with the
                # Android KV parser: trim and normalize keys before alias
                # matching, while never emitting the value itself.
                name = toupper(name)
                upper = toupper(value)
                if (matches(name) && value != "" && upper !~ /^(UNKNOWN|NOT_RETAINED|SSH_KEY_ONLY)/) found = 1
              }
              END { exit(found ? 0 : 1) }
            ' "${'$'}file" >/dev/null 2>&1; then
              return 0
            fi
          done < <(candidate_files)
          return 1
        }
        source_name=unavailable
        for dir in /root/.config/proxy-runbook /root/.config/text-node-assistant /root/.config/proxy-node-assistant; do
          if [ -r "${'$'}dir/CURRENT-LOGIN-CREDENTIALS.env" ] || [ -r "${'$'}dir/HANDOFF-SECRETS.txt" ]; then
            source_name=handoff
            break
          fi
          if [ -d "${'$'}dir/handoff-archive" ] && command -v find >/dev/null 2>&1 &&
             [ -n "${'$'}(find "${'$'}dir/handoff-archive" -maxdepth 1 -type f -name 'HANDOFF-*.txt' -print -quit 2>/dev/null)" ]; then
            source_name=handoff-archive
            break
          fi
        done
        vps_user=0; vps_password=0; panel_user=0; panel_password=0
        value_present VPS_LOGIN_USER && vps_user=1 || true
        value_present VPS_LOGIN_PASSWORD && vps_password=1 || true
        value_present PANEL_USERNAME && panel_user=1 || true
        value_present PANEL_PASSWORD && panel_password=1 || true
        complete=0
        if [ "${'$'}vps_user" = 1 ] && [ "${'$'}vps_password" = 1 ] && [ "${'$'}panel_user" = 1 ] && [ "${'$'}panel_password" = 1 ]; then complete=1; fi
        printf 'VPS_LOGIN_USER_PRESENT=%s\nVPS_LOGIN_PASSWORD_PRESENT=%s\nPANEL_USERNAME_PRESENT=%s\nPANEL_PASSWORD_PRESENT=%s\nCOMPLETE=%s\nSOURCE=%s\n' "${'$'}vps_user" "${'$'}vps_password" "${'$'}panel_user" "${'$'}panel_password" "${'$'}complete" "${'$'}source_name"
        printf '%s\n' '${ProtocolParsers.CREDENTIAL_READINESS_END}'
    """.trimIndent()

    /**
     * Best-effort readiness probe.  An unavailable/legacy handoff leaves the
     * form usable with an explicit policy choice; only a validated complete
     * block changes the explanatory text next to PRESERVE.
     */
    private suspend fun detectCredentialReadiness(handle: SshHandle): CredentialReadiness {
        val result = runCatching { handle.exec(credentialReadinessCommand(), root = true, log = { }) }.getOrElse { error ->
            log("CREDENTIAL_HANDOFF_READY=UNKNOWN detail=${safeError(error)}")
            return CredentialReadiness.UNKNOWN
        }
        if (!result.ok) {
            log("CREDENTIAL_HANDOFF_READY=UNKNOWN detail=remote_exit_${result.exitCode}")
            return CredentialReadiness.UNKNOWN
        }
        return runCatching { ProtocolParsers.credentialReadiness(result.stdout) }.getOrElse { error ->
            log("CREDENTIAL_HANDOFF_READY=UNKNOWN detail=${safeError(error)}")
            CredentialReadiness.UNKNOWN
        }
    }

    private suspend fun detectExistingNode(handle: SshHandle): Boolean {
        val result = checked(
            handle,
	            "existing=0; if systemctl is-active --quiet x-ui 2>/dev/null || [ -x /usr/local/x-ui/x-ui ] || [ -s /etc/x-ui/x-ui.db ] || systemctl is-active --quiet proxy-node-assistant-ss2022.service 2>/dev/null || [ -s /etc/proxy-runbook/ss2022/service.env ] || [ -s /etc/text-node-assistant/ss2022/service.env ] || [ -s /etc/proxy-runbook/ss2022/server.json ] || [ -s /etc/text-node-assistant/ss2022/server.json ] || systemctl is-active --quiet tna-ss2022-112-trial.service 2>/dev/null; then existing=1; fi; printf 'TNA_EXISTING_NODE=%s\\n' \"\$existing\"",
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

        // Credentials are an explicit part of the install/upgrade plan.  The
        // mode is shown in the review, while custom secrets stay in memory
        // until they are written to the root-only one-run input file.
        val credentials = collectCredentialPlan(existingNode)
        val prune = confirmYes(tr("成功后清理冗余备份，仅保留一份已验证的当前配置备份？", "After success, prune redundant backups and retain one verified current-config backup?"), false, allowNo = true)
        val openPanel = confirmYes(tr("成功后通过本机 SSH 隧道打开 3x-ui 面板？", "After success, open the 3x-ui panel through a localhost SSH tunnel?"), true, allowNo = true)
        return AndroidInstallPlan(
            routeMode = route,
            coverChoice = coverChoice,
            performanceMode = performance,
            warpMode = warp,
            gray = gray,
            orange = orange,
            pruneAfterSuccess = prune,
            openPanelOnSuccess = openPanel,
            ss2022Port = ss2022Port,
            credentials = credentials,
        )
    }

    private suspend fun collectCredentialPlan(existingNode: Boolean): AndroidCredentialPlan {
        val vpsMode = chooseInstallCredentialMode(
            label = tr("VPS 登录密码策略", "VPS login password policy"),
            existingNode = existingNode,
            subject = tr("VPS 登录密码", "VPS login password"),
            readiness = credentialReadiness,
        )
        val vpsPassword = if (vpsMode == InstallCredentialMode.CUSTOM) {
            matchingSecret(
                tr("自定义 VPS 登录密码", "Custom VPS login password"),
                tr("输入 8—256 个字符；空格有意义，不写日志或设置。", "Enter 8-256 characters; spaces are meaningful and the value is never logged or persisted."),
            )
        } else ""

        val panelMode = chooseInstallCredentialMode(
            label = tr("3x-ui 面板凭据策略", "3x-ui panel credential policy"),
            existingNode = existingNode,
            subject = tr("3x-ui 面板账号和密码", "3x-ui panel username and password"),
            readiness = credentialReadiness,
        )
        val panelAccount: String
        val panelPassword: String
        if (panelMode == InstallCredentialMode.CUSTOM) {
            panelAccount = required(
                tr("自定义 3x-ui 面板账号", "Custom 3x-ui panel username"),
                tr("仅允许字母、数字、下划线、点和连字符；首字符必须是字母或下划线。", "Letters, digits, underscore, dot, and hyphen only; start with a letter or underscore."),
            ) { AndroidCredentialPlan.validPanelAccount(it) }
            panelPassword = matchingSecret(
                tr("自定义 3x-ui 面板密码", "Custom 3x-ui panel password"),
                tr("输入 8—256 个字符；空格有意义，不写日志或设置。", "Enter 8-256 characters; spaces are meaningful and the value is never logged or persisted."),
            )
        } else {
            panelAccount = ""
            panelPassword = ""
        }
        return AndroidCredentialPlan(vpsMode, vpsPassword, panelMode, panelAccount, panelPassword)
    }

    private suspend fun chooseInstallCredentialMode(
        label: String,
        existingNode: Boolean,
        subject: String,
        readiness: CredentialReadiness = CredentialReadiness.UNKNOWN,
    ): InstallCredentialMode {
        val preserveReady = existingNode && readiness.isComplete
        val options = buildList {
            if (existingNode) add(
                "PRESERVE | ${if (preserveReady) {
                    tr("已检测到完整交接，保留并让远端复核", "complete handoff detected; preserve and verify remotely")
                } else {
                    tr("保留当前已验证凭据", "keep the currently verified credentials")
                }}",
            )
            add("RANDOM | ${tr("生成并应用新的高强度随机值", "generate and apply a new high-entropy value")}")
            add("CUSTOM | ${tr("手动输入并二次确认", "enter and confirm manually")}")
        }
        val readinessMessage = if (existingNode) {
            if (preserveReady) {
                tr(
                    "已完成远端只读识别：四个登录字段均存在。选择 PRESERVE 即可继续，不需要刷新或重填密码；施工前仍会由远端再次验证。",
                    "The read-only remote check found all four login fields. Choose PRESERVE to continue without refreshing or re-entering a password; the remote installer still verifies it before changes.",
                )
            } else {
                tr(
                    "远端交接字段未完整识别（仅显示存在性：${readiness.summary()}）。请明确选择保留、随机或自定义；不会猜测或显示密码。",
                    "The remote handoff is not complete (presence only: ${readiness.summary()}). Choose preserve, random, or custom explicitly; no password is guessed or shown.",
                )
            }
        } else {
            tr(
                "新节点必须明确选择策略。自定义秘密只通过一次性 root-only 文件交给远端，绝不进入日志、命令行或本地设置。",
                "A fresh node requires an explicit policy. Custom secrets travel only in a one-run root-only file and never enter logs, command lines, or local settings.",
            )
        }
        val answer = prompts.ask(
            label,
            tr("为 $subject 选择本次策略。", "Choose the policy for $subject.") + "\n" + readinessMessage,
            PromptKind.CHOICE,
            options = options,
        )
        val token = answer.trim().substringBefore('|').substringBefore('｜').trim().lowercase(Locale.ROOT)
        return when {
            token == "preserve" || token == "p" || token == "0" || (token == "1" && existingNode) -> InstallCredentialMode.PRESERVE
            token == "random" || token == "r" || (token == "1" && !existingNode) || (token == "2" && existingNode) -> InstallCredentialMode.RANDOM
            token == "custom" || token == "c" || (token == "2" && !existingNode) || (token == "3" && existingNode) -> InstallCredentialMode.CUSTOM
            else -> error(tr("凭据策略选择无效", "Invalid credential policy selection"))
        }
    }

    /** Ask for a secret without trimming meaningful spaces, then confirm it. */
    private suspend fun matchingSecret(title: String, message: String): String {
        while (true) {
            val first = requiredSecret(title, message)
            val second = requiredSecret(
                tr("再次输入以确认", "Enter again to confirm"),
                tr("两次输入必须完全一致；空格和大小写均保留。", "The two entries must match exactly; spaces and case are preserved."),
            )
            if (first == second) return first
            log("INPUT_REJECTED: $title (confirmation mismatch)")
        }
    }

    private suspend fun requiredSecret(title: String, message: String): String {
        while (true) {
            val answer = Validation.singleLineSecret(prompts.ask(title, message, PromptKind.SECRET, placeholder = tr("至少 8 个字符", "at least 8 characters")))
            if (AndroidCredentialPlan.validSecret(answer)) return answer
            log("INPUT_REJECTED: $title (8..256 characters, no NUL/CR/LF)")
        }
    }

    private fun installAutoInput(plan: AndroidInstallPlan): String = buildString {
        appendLine("GRAY_DOMAIN_B64=${b64(plan.gray.domain)}")
        appendLine("GRAY_EMAIL_B64=${b64(plan.gray.email)}")
        appendLine("ORANGE_DOMAIN_B64=${b64(plan.orange.domain)}")
        appendLine("ORANGE_EMAIL_B64=${b64(plan.orange.email)}")
        appendLine("LANG=${if (language == Language.ZH) "zh" else "en"}")
        appendLine("VPS_PASSWORD_MODE=${plan.credentials.vpsMode.wireValue}")
        appendLine("PANEL_CREDENTIAL_MODE=${plan.credentials.panelMode.wireValue}")
        if (plan.credentials.vpsMode == InstallCredentialMode.CUSTOM) {
            appendLine("VPS_PASSWORD_B64=${b64(plan.credentials.vpsPassword)}")
        }
        if (plan.credentials.panelMode == InstallCredentialMode.CUSTOM) {
            appendLine("PANEL_USERNAME_B64=${b64(plan.credentials.panelAccount)}")
            appendLine("PANEL_PASSWORD_B64=${b64(plan.credentials.panelPassword)}")
        }
    }

    /**
     * Create a root-owned, 0600 one-run input file without exposing its
     * contents in an SSH command, process listing, or ordinary workflow log.
     * The runbook accepts these names during its bounded credential phase.
     */
    private suspend fun writeOneRunInput(handle: SshHandle, content: String, kind: String): String {
        require(kind == "auto-input" || kind == "credential-input") { "unsupported one-run input kind" }
        // Keep the name in the same namespace/shape enforced by the v1
        // runbook: the random suffix is the complete basename (no extension).
        val path = "/tmp/proxy-node-assistant-$kind-${randomToken()}"
        val payload = Base64.encodeToString(content.toByteArray(Charsets.UTF_8), Base64.NO_WRAP) + "\n"
        val payloadBytes = payload.toByteArray(Charsets.US_ASCII)
        try {
            val result = handle.exec(
                // `head -c` consumes the exact payload and closes its pipe.  This
                // gives base64 an EOF even though the SSH session remains open
                // for the command's stdout/stderr pumps.
                "set -Eeuo pipefail; umask 077; set -C; head -c ${payloadBytes.size} | base64 -d > ${SshHandle.shellQuote(path)}; set +C; chmod 600 ${SshHandle.shellQuote(path)}; test \"\$(stat -c '%u %a' ${SshHandle.shellQuote(path)} 2>/dev/null)\" = '0 600'",
                root = true,
                stdinBytes = payloadBytes,
                log = { },
            )
            check(result.ok) { "one-run input creation failed (exit ${result.exitCode})" }
            return path
        } catch (error: Throwable) {
            // The caller cannot receive the path when exec/check fails.  Clean
            // it here in a non-cancellable context so a failed or cancelled
            // [5]/[6] custom-credential run never leaves a root-readable secret
            // in /tmp.  The command is bounded by removeOneRunInput's exact
            // namespace/shape check.
            withContext(NonCancellable) { removeOneRunInput(handle, path) }
            throw error
        }
    }

    private suspend fun removeOneRunInput(handle: SshHandle, path: String) {
        if (!Regex("^/tmp/proxy-node-assistant-(auto-input|credential-input)-[0-9a-f]{24}$").matches(path)) return
        runCatching { handle.exec("rm -f -- ${SshHandle.shellQuote(path)}", root = true, log = { }) }
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
            val linkResult = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh link ${SshHandle.shellQuote(plan.orange.domain)} 8443", emit = false)
            val stageEvidence = ProtocolParsers.cdnStageEvidence(staged.stdout, staged.stderr, linkResult.stdout, linkResult.stderr)
            // Keep the explicit topology marker check in addition to the
            // structured parser.  This prevents a future parser broadening
            // from turning a successful command with no staged transaction
            // into a public route mutation.
            require(
                "TNA_TOPOLOGY_STAGED=1" in staged.stdout || "TNA_TOPOLOGY_STAGED=1" in staged.stderr,
            ) { "CDN topology staged marker missing" }
            require(
                stageEvidence.topologyStaged && stageEvidence.certificateReady && stageEvidence.xhttpReady &&
                    stageEvidence.nginxStaged && stageEvidence.originReady && stageEvidence.edgeValidated,
            ) {
                "CDN stage evidence incomplete: topology=${stageEvidence.topologyStaged}, cert=${stageEvidence.certificateReady}, " +
                    "xhttp=${stageEvidence.xhttpReady}, nginx=${stageEvidence.nginxStaged}, origin=${stageEvidence.originReady}, edge=${stageEvidence.edgeValidated}"
            }
            val rawLink = Regex("vless://[^\\s]+", RegexOption.IGNORE_CASE).find(linkResult.stdout)?.value
                ?: error(tr("远端没有生成可测试的 CDN/XHTTP 链接", "The server did not produce a testable CDN/XHTTP link"))
            // Legacy 0.9.x exporters may still return a TNA-* fragment. Read
            // that spelling for upgrades, but never place it back into the
            // protected v1 handoff or the real-browse prompt. The formatter
            // changes only the fragment and preserves optional query knobs.
            val link = ProtocolParsers.canonicalizeCdnXHttpLink(rawLink)
            val profile = ProtocolParsers.cdnXHttpLink(link)
            require(profile.domain.equals(plan.orange.domain, ignoreCase = true) && profile.port == 8443) {
                "CDN/XHTTP link endpoint does not match the staged orange hostname"
            }
            // Keep the complete route handoff in the protected panel.  The link
            // itself is never written to the ordinary workflow log.
            _state.update {
                it.copy(
                    secretHandoff = buildString {
                        appendLine("===== PROXYNODEASSISTANT CDN/XHTTP STAGE =====")
                        appendLine("CDN_XHTTP_LINK=$link")
                        appendLine("CDN_XHTTP_DOMAIN=${profile.domain}")
                        appendLine("CDN_XHTTP_PORT=${profile.port}")
                        appendLine("CDN_XHTTP_PATH=${profile.path}")
                        appendLine("CDN_STAGE_CERTIFICATE=READY")
                        appendLine("CDN_STAGE_XHTTP=READY")
                        appendLine("CDN_STAGE_ORIGIN=READY_CLOUDFLARE_ONLY")
                        appendLine("CDN_STAGE_EDGE=VALIDATED")
                        append("REAL_BROWSE_REQUIRED_BEFORE_COMMIT=1")
                    },
                )
            }
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
            val clientConfirmed = checked(handle, "bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh --confirm-client ${SshHandle.shellQuote(plan.orange.domain)}", interactive = true)
            val clientEvidence = ProtocolParsers.cdnStageEvidence(clientConfirmed.stdout, clientConfirmed.stderr)
            require(clientEvidence.clientConfirmed) { "CDN real-client confirmation marker missing" }
            val finalized = checked(handle, "bash $REMOTE_ROOT/linux/28-topology-reconcile.sh --finalize", interactive = true)
            val finalState = checked(
                handle,
                "cat /etc/proxy-runbook/cloudflare/edge-state.env 2>/dev/null; cat /etc/text-node-assistant/cloudflare/edge-state.env 2>/dev/null",
                emit = false,
            )
            val finalEvidence = ProtocolParsers.cdnStageEvidence(finalized.stdout, finalized.stderr, finalState.stdout, finalState.stderr)
            require(
                finalEvidence.topologyReconciled && finalEvidence.edgeValidated && finalEvidence.clientConfirmed &&
                    finalEvidence.mode == plan.routeMode.wireValue,
            ) {
                "CDN topology finalization evidence incomplete: reconciled=${finalEvidence.topologyReconciled}, " +
                    "mode=${finalEvidence.mode ?: "?"}, edge=${finalEvidence.edgeValidated}, client=${finalEvidence.clientConfirmed}"
            }
            completed = true
        } finally {
            if (!completed) {
                val rollback = runCatching {
                    handle.exec("bash $REMOTE_ROOT/linux/28-topology-reconcile.sh --rollback-pending", root = true, log = { })
                }.getOrNull()
                val evidence = rollback?.let { ProtocolParsers.cdnStageEvidence(it.stdout, it.stderr) }
                if (rollback?.ok == true && evidence?.rolledBack == true) {
                    log("CDN_ROLLBACK_MARKER=TNA_TOPOLOGY_ROLLED_BACK=1")
                } else {
                    log("CDN_ROLLBACK_MARKER=FAILED")
                }
            }
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
            val localReady = addresses.isNotEmpty() && addresses.none { it.hostAddress == publicIp }
            // A local resolver may be intercepted or stale on mobile networks;
            // query two independent public DoH resolvers as a corroborating
            // signal.  This remains a reachability check, not a Cloudflare API
            // claim, and never sends credentials.
            val dohReady = orangeDnsDohQuorum(domain, publicIp)
            if (localReady || dohReady) {
                log("ORANGE_DNS_READY local=$localReady doh_quorum=$dohReady; proxied hostname does not expose origin IPv4")
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

    private fun orangeDnsDohQuorum(domain: String, originIp: String): Boolean {
        val endpoints = listOf(
            "https://cloudflare-dns.com/dns-query?name=$domain&type=A",
            "https://dns.google/resolve?name=$domain&type=A",
        )
        var successes = 0
        endpoints.forEach { endpoint ->
            val ok = runCatching {
                val connection = URL(endpoint).openConnection(Proxy.NO_PROXY) as HttpsURLConnection
                connection.connectTimeout = 8_000
                connection.readTimeout = 8_000
                connection.requestMethod = "GET"
                connection.setRequestProperty("Accept", "application/dns-json")
                try {
                    val body = connection.inputStream.bufferedReader().use { it.readText() }
                    val addresses = Regex("\\\"data\\\"\\s*:\\s*\\\"([0-9.]+)\\\"").findAll(body).map { it.groupValues[1] }.toList()
                    connection.responseCode in 200..299 && addresses.isNotEmpty() && addresses.none { it == originIp }
                } finally {
                    connection.disconnect()
                }
            }.getOrDefault(false)
            if (ok) successes++
        }
        return successes == endpoints.size
    }

    /**
     * Explain the origin-certificate prerequisites explicitly.  Universal SSL
     * (edge certificate) and the VPS origin certificate are different things;
     * this gate prevents the common misconfiguration where an Access/challenge
     * rule blocks HTTP-01 and the install later reports a misleading timeout.
     */
    private suspend fun guideCloudflareCertificatePrerequisites(domain: String) {
        val steps = listOf(
            tr("确认 $domain 的 A 记录指向当前 VPS 并已开启橙云 Proxied。", "Confirm $domain points to this VPS and is Cloudflare Proxied."),
            tr("确认该 hostname 没有 Access、Turnstile、质询、Worker 或重定向拦截 /.well-known/acme-challenge/。", "Confirm no Access, Turnstile, challenge, Worker, or redirect intercepts /.well-known/acme-challenge/ on this hostname."),
            tr("了解 Universal SSL 只覆盖客户端到 Cloudflare 边缘；VPS 源站证书仍由本流程用手填邮箱签发，不需要 Cloudflare API Token。", "Understand that Universal SSL covers client-to-edge only; this flow still issues the VPS origin certificate with the entered email and does not need a Cloudflare API token."),
        )
        steps.forEachIndexed { index, step ->
            val answer = prompts.ask(
                tr("橙云源站前置 ${index + 1}/${steps.size}", "Orange-origin prerequisite ${index + 1}/${steps.size}"),
                "$step\n${tr("确认后按 Enter；输入 q 取消。", "Press Enter to confirm; type q to cancel.")}",
                PromptKind.TEXT,
            )
            if (answer.trim().equals("q", true)) throw CancellationException("CLOUDFLARE_PREREQUISITE_CANCELLED")
        }
    }

    /** Bounded security-event reader retained from v0.9.5 (no device/drive state). */
    private suspend fun securityEvents(handle: SshHandle) {
        while (true) {
            val choice = required(
                tr("访问与封禁日志", "Access and ban events"),
                tr("1=最近24小时，2=选择范围，3=安装/修复受管 Fail2ban，4=查看基线，0=返回", "1=last 24 h, 2=choose range, 3=install/repair managed Fail2ban, 4=baseline status, 0=back"),
                "1",
            ) { it in setOf("0", "1", "2", "3", "4") }
            when (choice) {
                "0" -> return
                "3" -> {
                    if (!confirmYes(
                            tr("应用受管 sshd jail（5 次/10 分钟，封禁 1 小时）和隐私化连接元数据规则？", "Apply the managed sshd jail (5 attempts/10 minutes, one-hour ban) and privacy-preserving connection metadata?"),
                            false,
                            allowNo = true,
                        )) continue
                    val applied = checked(handle, "bash $REMOTE_ROOT/linux/24-security-baseline.sh --apply 7", emit = false)
                    require("TNA_SECURITY_BASELINE_APPLIED" in applied.stdout && "TNA_SECURITY_BASELINE_STATUS_END" in applied.stdout) {
                        tr("安全基线返回不完整", "Security-baseline response was incomplete")
                    }
                    log(applied.stdout.trim())
                }
                "4" -> {
                    val status = checked(handle, "bash $REMOTE_ROOT/linux/24-security-baseline.sh --status", emit = false)
                    require("TNA_SECURITY_BASELINE_STATUS_BEGIN" in status.stdout && "TNA_SECURITY_BASELINE_STATUS_END" in status.stdout) {
                        tr("安全基线状态返回不完整", "Security-baseline status was incomplete")
                    }
                    log(status.stdout.trim())
                }
                else -> {
                    val since = if (choice == "2") required(
                        tr("时间范围", "Time range"),
                        "1h / 6h / 24h / 7d",
                        "24h",
                    ) { it in setOf("1h", "6h", "24h", "7d") } else "24h"
                    val result = checked(handle, "bash $REMOTE_ROOT/linux/25-security-events.sh --protocol-v1 --since ${SshHandle.shellQuote(since)} --cursor 0 --limit 200", emit = false)
                    require(result.stdout.count { it == '\n' } <= 1300) {
                        tr("安全事件响应超过边界", "Security-event response exceeded its bound")
                    }
                    val bounded = result.stdout
                    require(
                        ("__TNA_SECURITY_V1_BEGIN__" in bounded || "__PNA_SECURITY_V1_BEGIN__" in bounded) &&
                            ("__TNA_SECURITY_V1_END__" in bounded || "__PNA_SECURITY_V1_END__" in bounded) &&
                            "SUMMARY\t" in bounded,
                    ) { tr("安全事件协议返回不完整", "Security-event protocol response was incomplete") }
                    log(tr("连接/失败事件不自动等同攻击；只有 Fail2ban 当前封禁具有明确封禁语义。", "Connection/failure events are not automatically attacks; only current Fail2ban bans have explicit ban semantics."))
                    log(bounded.trim())
                }
            }
        }
    }

    /**
     * CDN/XHTTP control center retained from v0.9.5.  Route controls are
     * deliberately separate from node/client identity: no enrollment gate or
     * storage feature is involved.  Every mutating branch has an explicit
     * confirmation and consumes the marker protocol emitted by 04f/05e/05f/
     * 05g/05h; a zero exit status without the marker is treated as failure.
     */
    private suspend fun cdnXhttpControl(handle: SshHandle) {
        val choice = prompts.ask(
            tr("CDN / XHTTP 控制中心", "CDN / XHTTP control center"),
            tr(
                "[1] 脱敏状态  [2] 回环影子  [3] 生成并校验 8443 链接  [4] Cloudflare CIDR 计划\n[5] 签证并晋升 Cloudflare-only 8443  [6] 验证橙云边缘并生成链接  [7] 真机浏览后提交\n[8] 回滚公网 8443  [9] 删除 CDN/XHTTP 组件  [0] 返回",
                "[1] Redacted status  [2] Loopback shadow  [3] Generate/validate the 8443 link  [4] Cloudflare CIDR plan\n[5] Issue certificate and promote Cloudflare-only 8443  [6] Validate the orange edge and generate a link  [7] Commit after real browsing\n[8] Roll back public 8443  [9] Remove CDN/XHTTP components  [0] Back",
            ),
            PromptKind.TEXT,
            defaultValue = "1",
        ).trim().ifEmpty { "1" }
        when (choice) {
            "0" -> return
            "1" -> cdnStatus(handle)
            "2" -> cdnLoopbackStage(handle)
            "3" -> cdnStageLink(handle)
            "4" -> cdnCloudflarePlan(handle)
            "5" -> cdnPromotePublic(handle)
            "6" -> cdnValidateEdge(handle)
            "7" -> cdnConfirmClient(handle)
            "8" -> cdnRollbackPublic(handle)
            "9" -> cdnRemoveComponents(handle)
            else -> error(tr("CDN/XHTTP 选项无效", "Invalid CDN/XHTTP selection"))
        }
    }

    private suspend fun cdnStatus(handle: SshHandle) {
        val command = """
            set -u
            if [ -r $REMOTE_ROOT/linux/lib-deployment-state.sh ]; then
              . $REMOTE_ROOT/linux/lib-deployment-state.sh
              type tna_state_init_direct_if_missing >/dev/null 2>&1 && tna_state_init_direct_if_missing || true
              type tna_state_show >/dev/null 2>&1 && tna_state_show || true
            fi
            for file in /root/.config/proxy-node-assistant/topology.env /root/.config/text-node-assistant/topology.env /etc/proxy-runbook/topology.env /etc/text-node-assistant/topology.env; do
              [ -r "${'$'}file" ] || continue
              sed -n -E '/^(TOPOLOGY_MODE|ROUTE_MODE|GRAY_DOMAIN|ORANGE_DOMAIN|GRAY_DNS_VALIDATED|ORANGE_EDGE_VALIDATED|ACTIVE_MODE|DEPLOYMENT_MODE)=/p' "${'$'}file"
            done
            if [ -x $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh ] && bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh show >/dev/null 2>&1; then
              echo XHTTP_COMPONENT=READY_LOOPBACK
            else
              echo XHTTP_COMPONENT=NOT_READY
            fi
            for file in /etc/proxy-runbook/cloudflare/edge-state.env /etc/text-node-assistant/cloudflare/edge-state.env; do
              [ -r "${'$'}file" ] || continue
              sed -n -E '/^(CDN_EDGE_VALIDATED|CDN_CLIENT_CONFIRMED|CDN_EDGE_DOMAIN|CDN_EDGE_PORT|CDN_ORIGIN_PORT)=/p' "${'$'}file"
            done
            if [ -x $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh ]; then
              bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh status 2>/dev/null || true
            fi
            echo TOPOLOGY_MUTATION=NONE
            echo TOPOLOGY_CHANGE_ENTRY=ACTION_22_STATUS
        """.trimIndent()
        checked(handle, command)
    }

    /** Stage only the loopback shadow; no public listener or Cloudflare rule is opened. */
    private suspend fun cdnLoopbackStage(handle: SshHandle) {
        val domain = required(
            tr("回环施工域名", "Loopback deployment hostname"),
            tr("输入已由当前源站证书覆盖的域名；此操作只修改本机回环 Nginx/XHTTP。", "Enter a hostname covered by the current origin certificate; this only changes the local loopback Nginx/XHTTP stage."),
        ) { Validation.validDomain(it) }.lowercase(Locale.ROOT)
        confirmYes(
            tr("确认只做回环影子验收，不公开 8443、不修改 Cloudflare/UFW？", "Confirm loopback-only staging: do not expose 8443 or change Cloudflare/UFW?"),
            false,
        )
        val publicIp = cdnPublicIp(handle)
        val create = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh create ${SshHandle.shellQuote(domain)}", emit = false)
        val createEvidence = ProtocolParsers.cdnStageEvidence(create.stdout, create.stderr)
        require(createEvidence.xhttpReady) { "04f XHTTP readiness marker missing" }
        val stage = checked(handle, "bash $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh stage-local ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)}", emit = false)
        val stageEvidence = ProtocolParsers.cdnStageEvidence(stage.stdout, stage.stderr)
        require(stageEvidence.nginxStaged && "CDN_STAGE_SCOPE=LOCAL_ONLY" in stage.stdout) { "05e loopback stage marker missing" }
        val local = checked(
            handle,
            "curl --noproxy '*' --fail --silent --show-error --max-time 10 --resolve ${SshHandle.shellQuote("$domain:8443:127.0.0.2")} ${SshHandle.shellQuote("https://$domain:8443/")} >/dev/null; " +
                "! ss -H -lnt 2>/dev/null | awk -v a=${SshHandle.shellQuote("$publicIp:8443")} '\$4 == a {found=1} END{exit found ? 0 : 1}'; " +
                "echo CDN_LOCAL_VALIDATION=PASS; echo PUBLIC_ORIGIN_8443=NOT_ENABLED",
            emit = false,
        )
        require("CDN_LOCAL_VALIDATION=PASS" in local.stdout && "PUBLIC_ORIGIN_8443=NOT_ENABLED" in local.stdout) { "loopback validation marker missing" }
        log(tr("[GOOD] 回环 XHTTP/Nginx 影子验收通过；公网 8443 与 Cloudflare 未修改。", "[GOOD] Loopback XHTTP/Nginx shadow passed; public 8443 and Cloudflare were not changed."))
    }

    private suspend fun cdnStageLink(handle: SshHandle) {
        val domain = required(
            tr("XHTTP 域名", "XHTTP hostname"),
            tr("输入创建 XHTTP 入站时使用的域名", "Enter the hostname used when creating the XHTTP inbound"),
        ) { Validation.validDomain(it) }.lowercase(Locale.ROOT)
        val result = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh link ${SshHandle.shellQuote(domain)} 8443", emit = false)
        val rawLink = Regex("vless://[^\\s]+", RegexOption.IGNORE_CASE).find(result.stdout)?.value
            ?: error(tr("远端没有返回 XHTTP 链接", "The server returned no XHTTP link"))
        val link = ProtocolParsers.canonicalizeCdnXHttpLink(rawLink)
        val profile = ProtocolParsers.cdnXHttpLink(link)
        require(profile.domain.equals(domain, ignoreCase = true) && profile.port == 8443) { "XHTTP link endpoint mismatch" }
        _state.update {
            it.copy(
                secretHandoff = buildString {
                    appendLine("===== PROXYNODEASSISTANT CDN/XHTTP LINK =====")
                    appendLine("CDN_XHTTP_STAGE_LINK=$link")
                    appendLine("CDN_XHTTP_DOMAIN=${profile.domain}")
                    appendLine("CDN_XHTTP_PORT=${profile.port}")
                    append("CDN_XHTTP_PATH=${profile.path}")
                },
            )
        }
        log("CDN_XHTTP_LINK_VALIDATED port=${profile.port}; link is available only in the protected handoff panel")
    }

    private suspend fun cdnCloudflarePlan(handle: SshHandle) {
        val status = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh status", emit = false)
        val values = ProtocolParsers.kv(status.stdout)
        if (values["CLOUDFLARE_FIREWALL_APPLIED"] == "1") {
            log(tr("8443 Cloudflare-only 锁已应用；如需刷新 CIDR，先使用 [8] 回滚。", "The Cloudflare-only 8443 lock is already applied; use [8] before refreshing CIDRs."))
            log(status.stdout.trim())
            return
        }
        val fetched = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh fetch", emit = false)
        val plan = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh plan ${handle.target.port}", emit = false)
        val planText = fetched.stdout + "\n" + plan.stdout
        require("PLAN_ONLY=1" in planText && ("KEEP_PUBLIC_TCP_443_UNCHANGED=1" in planText || "KEEP_REALITY_PUBLIC_TCP=443" in planText)) {
            "05f Cloudflare CIDR plan marker missing"
        }
        log(plan.stdout.trim())
    }

    /**
     * Run the complete certificate → XHTTP → origin-lock → Nginx → origin
     * validation sequence.  The operation is intentionally staged; edge and
     * real-client confirmation remain separate choices below.
     */
    private suspend fun cdnPromotePublic(handle: SshHandle) {
        val domain = required(
            tr("施工域名", "Deployment hostname"),
            tr("输入已配置或即将配置橙云的域名", "Enter the hostname configured (or about to be configured) for orange-cloud"),
        ) { Validation.validDomain(it) }.lowercase(Locale.ROOT)
        val email = required(
            tr("证书邮箱", "Certificate email"),
            tr("用于 ACME 源站证书；不会写入普通日志", "Used for the ACME origin certificate; never written to the ordinary log"),
        ) { Validation.validEmail(it) }
        confirmYes(
            tr("将签发/复用源站证书，并把 8443 锁为 Cloudflare 官方 CIDR；SSH、443 和 Reality 不动。继续？", "Issue/reuse the origin certificate and lock 8443 to official Cloudflare CIDRs; SSH, 443, and Reality remain unchanged. Continue?"),
            false,
        )
        val publicIp = cdnPublicIp(handle)
        val input = cdnInputPaths(handle, domain, email, publicIp)
        var lockAdded = false
        var stageAttempted = false
        try {
            // 05h deliberately refuses to expose its temporary ACME listener
            // until the Cloudflare-only :8443 allowlist is active.  Keep this
            // ordering identical to the v0.9.5 reconciler: lock -> cert ->
            // XHTTP -> permanent Nginx stage -> origin validation.
            val lockStatus = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh status", emit = false)
            if (ProtocolParsers.kv(lockStatus.stdout)["CLOUDFLARE_FIREWALL_APPLIED"] != "1") {
                checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh fetch", emit = false)
                val lockPlan = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh plan ${handle.target.port}", emit = false)
                require("PLAN_ONLY=1" in lockPlan.stdout && ("KEEP_PUBLIC_TCP_443_UNCHANGED=1" in lockPlan.stdout || "KEEP_REALITY_PUBLIC_TCP=443" in lockPlan.stdout)) {
                    "05f lock plan marker missing"
                }
                val applied = checked(handle, "bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh apply", emit = false)
                val appliedEvidence = ProtocolParsers.cdnStageEvidence(applied.stdout, applied.stderr)
                require("CLOUDFLARE_FIREWALL_APPLIED=1" in applied.stdout && "PUBLIC_TCP_443_POLICY=UNCHANGED" in applied.stdout) {
                    "05f lock apply marker missing"
                }
                lockAdded = appliedEvidence.originReady || "CLOUDFLARE_FIREWALL_APPLIED=1" in applied.stdout
            }

            val certificate = checked(handle, "bash $REMOTE_ROOT/linux/05h-ensure-cdn-certificate.sh --input-file ${SshHandle.shellQuote(input.runtimePath)}", emit = false)
            require(ProtocolParsers.cdnStageEvidence(certificate.stdout, certificate.stderr).certificateReady) { "05h certificate marker missing" }

            val create = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh create ${SshHandle.shellQuote(domain)}", emit = false)
            require(ProtocolParsers.cdnStageEvidence(create.stdout, create.stderr).xhttpReady) { "04f XHTTP marker missing" }

            // Keep the original v0.9.5 safety sequence: validate the managed
            // XHTTP/Nginx shadow on 127.0.0.2 before exposing the concrete
            // public :8443 listener.  A failed local probe is rolled back by
            // the transaction and never reaches Cloudflare.
            stageAttempted = true
            val localStage = checked(
                handle,
                "TNA_TARGET_TOPOLOGY=orange bash $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh stage-local ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)}",
                emit = false,
            )
            val localStageEvidence = ProtocolParsers.cdnStageEvidence(localStage.stdout, localStage.stderr)
            require(localStageEvidence.nginxStaged && "CDN_STAGE_SCOPE=LOCAL_ONLY" in localStage.stdout) { "05e loopback stage marker missing" }
            val localProbe = checked(
                handle,
                "curl --noproxy '*' --fail --silent --show-error --max-time 10 --resolve ${SshHandle.shellQuote("$domain:8443:127.0.0.2")} ${SshHandle.shellQuote("https://$domain:8443/")} >/dev/null; echo CDN_LOCAL_VALIDATION=PASS",
                emit = false,
            )
            require("CDN_LOCAL_VALIDATION=PASS" in localProbe.stdout) { "local CDN/XHTTP probe marker missing" }

            val stage = checked(handle, "TNA_TARGET_TOPOLOGY=orange bash $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh stage ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)}", emit = false)
            val stageEvidence = ProtocolParsers.cdnStageEvidence(stage.stdout, stage.stderr)
            require(stageEvidence.nginxStaged && "CDN_STAGE_SCOPE=CLOUDFLARE_ONLY" in stage.stdout) { "05e public stage marker missing" }
            val origin = checked(handle, "TNA_TARGET_TOPOLOGY=orange bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh --origin-ready ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)}", emit = false)
            require(ProtocolParsers.cdnStageEvidence(origin.stdout, origin.stderr).originReady) { "05g origin marker missing" }
            verifyDirectOriginBlocked(publicIp)
            log("CDN_PUBLIC_ORIGIN_READY=1 CDN_ORIGIN_SCOPE=CLOUDFLARE_ONLY CDN_ORIGIN_PORT=8443")
            log(tr("[GOOD] 8443 已锁定为 Cloudflare-only；请在 Cloudflare 配置橙云、Full(strict)、缓存绕过后运行 [6]。", "[GOOD] 8443 is locked to Cloudflare-only; configure orange-cloud, Full(strict), and cache bypass in Cloudflare, then run [6]."))
            log("CLOUDFLARE_DASHBOARD_OPENED=${openCloudflareDnsDashboard()}")
        } catch (error: Throwable) {
            if (stageAttempted || lockAdded) {
                val rolled = rollbackCdnPublic(handle, removeStage = stageAttempted, removeLock = lockAdded, resetEdge = true)
                log("CDN_PUBLIC_ORIGIN_ROLLBACK=${if (rolled) "1" else "FAILED"}")
            }
            throw error
        } finally {
            runCatching { handle.exec("rm -f -- ${SshHandle.shellQuote(input.tempPath)} ${SshHandle.shellQuote(input.runtimePath)}", root = true, log = { }) }
        }
    }

    private suspend fun cdnValidateEdge(handle: SshHandle) {
        val domain = required(
            tr("橙云施工域名", "Orange-cloud hostname"),
            tr("输入已经配置橙云与必要 Origin Rule 的域名", "Enter the hostname with orange-cloud and the required Origin Rule configured"),
        ) { Validation.validDomain(it) }.lowercase(Locale.ROOT)
        confirmYes(
            tr("确认橙云、Full(strict)、8443 源站规则、缓存绕过且没有拦截规则？", "Confirm orange-cloud, Full(strict), the 8443 origin rule, cache bypass, and no interception rules?"),
            false,
        )
        val publicIp = cdnPublicIp(handle)
        verifyCloudflareEdge(domain, 8443)
        verifyDirectOriginBlocked(publicIp)
        val remote = checked(handle, "TNA_TARGET_TOPOLOGY=orange bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh --edge ${SshHandle.shellQuote(domain)} ${SshHandle.shellQuote(publicIp)}", emit = false)
        require(ProtocolParsers.cdnStageEvidence(remote.stdout, remote.stderr).edgeValidated) { "05g edge marker missing" }
        val result = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh link ${SshHandle.shellQuote(domain)} 8443", emit = false)
        val rawLink = Regex("vless://[^\\s]+", RegexOption.IGNORE_CASE).find(result.stdout)?.value
            ?: error(tr("没有生成 CDN/XHTTP 链接", "No CDN/XHTTP link was generated"))
        val link = ProtocolParsers.canonicalizeCdnXHttpLink(rawLink)
        val profile = ProtocolParsers.cdnXHttpLink(link)
        require(profile.domain.equals(domain, ignoreCase = true) && profile.port == 8443) { "CDN edge link endpoint mismatch" }
        _state.update {
            it.copy(
                secretHandoff = buildString {
                    appendLine("===== PROXYNODEASSISTANT CDN/XHTTP EDGE =====")
                    appendLine("CDN_XHTTP_LINK=$link")
                    appendLine("CDN_EDGE_DOMAIN=${profile.domain}")
                    appendLine("CDN_EDGE_PORT=${profile.port}")
                    appendLine("CDN_ORIGIN_PORT=8443")
                    appendLine("CDN_EDGE_VALIDATED=1")
                    append("REAL_BROWSE_REQUIRED_BEFORE_COMMIT=1")
                },
            )
        }
        log("CDN_EDGE_VALIDATED=1; link is available only in the protected handoff panel")
    }

    private suspend fun cdnConfirmClient(handle: SshHandle) {
        val domain = required(
            tr("已验收域名", "Validated hostname"),
            tr("输入刚才导入客户端并真实浏览的域名", "Enter the hostname imported into the client and used for real browsing"),
        ) { Validation.validDomain(it) }.lowercase(Locale.ROOT)
        val exact = prompts.ask(
            tr("真机浏览确认", "Real-client confirmation"),
            tr("真实浏览成功后输入大写 REAL BROWSE OK；其他输入不会提交活动状态。", "After real browsing succeeds, type uppercase REAL BROWSE OK; any other input leaves the active state uncommitted."),
            PromptKind.EXACT_CONFIRMATION,
            placeholder = "REAL BROWSE OK",
            danger = true,
        ).trim()
        require(exact == "REAL BROWSE OK") { tr("未提交 CDN 活动状态", "CDN active state was not committed") }
        val result = checked(handle, "TNA_TARGET_TOPOLOGY=orange bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh --confirm-client ${SshHandle.shellQuote(domain)}", emit = false)
        require(ProtocolParsers.cdnStageEvidence(result.stdout, result.stderr).clientConfirmed) { "05g real-client marker missing" }

        // If action [1] left a topology transaction waiting for this manual
        // confirmation, finish it here.  A standalone manual promotion has no
        // transaction and therefore only records the verified edge state.
        val tx = runCatching { handle.exec("bash $REMOTE_ROOT/linux/28-topology-reconcile.sh --status", root = true, log = { }) }.getOrNull()
        if (tx?.ok == true && "TRANSACTION_STATUS=ACTIVE" in tx.stdout) {
            val finalized = checked(handle, "bash $REMOTE_ROOT/linux/28-topology-reconcile.sh --finalize", interactive = true)
            val evidence = ProtocolParsers.cdnStageEvidence(finalized.stdout, finalized.stderr)
            require(evidence.topologyReconciled) { "topology finalization marker missing" }
        }
        log("CDN_REAL_CLIENT_CONFIRMED=1")
    }

    private suspend fun cdnRollbackPublic(handle: SshHandle) {
        required(
            tr("当前 CDN 域名", "Current CDN hostname"),
            tr("输入当前 CDN/XHTTP 域名以确认目标", "Enter the current CDN/XHTTP hostname to identify the target"),
        ) { Validation.validDomain(it) }
        val exact = prompts.ask(
            tr("撤回公网源站", "Roll back public origin"),
            tr("输入大写 ROLLBACK CDN ORIGIN；回环影子和 Reality 443 保留。", "Type uppercase ROLLBACK CDN ORIGIN; the loopback shadow and Reality 443 remain."),
            PromptKind.EXACT_CONFIRMATION,
            placeholder = "ROLLBACK CDN ORIGIN",
            danger = true,
        ).trim()
        require(exact == "ROLLBACK CDN ORIGIN") { tr("已取消撤回", "Rollback cancelled") }
        require(rollbackCdnPublic(handle, removeStage = true, removeLock = true, resetEdge = true)) {
            tr("公网 CDN 撤回未返回完整证据", "Public CDN rollback did not return complete evidence")
        }
    }

    private suspend fun cdnRemoveComponents(handle: SshHandle) {
        val exact = prompts.ask(
            tr("删除 CDN/XHTTP 组件", "Remove CDN/XHTTP components"),
            tr("输入大写 REMOVE XHTTP COMPONENTS；只删除本工具管理的 XHTTP/Nginx/8443 锁，不动 SSH、Reality 443 或伪装站模板。", "Type uppercase REMOVE XHTTP COMPONENTS; only this tool's XHTTP/Nginx/8443-lock components are removed. SSH, Reality 443, and cover templates are untouched."),
            PromptKind.EXACT_CONFIRMATION,
            placeholder = "REMOVE XHTTP COMPONENTS",
            danger = true,
        ).trim()
        require(exact == "REMOVE XHTTP COMPONENTS") { tr("已取消删除", "Removal cancelled") }
        require(rollbackCdnPublic(handle, removeStage = true, removeLock = true, resetEdge = true)) {
            tr("删除前的 CDN 回滚未完成", "CDN rollback before removal did not complete")
        }
        val deleted = checked(handle, "bash $REMOTE_ROOT/linux/04f-xhttp-cdn-api.sh delete", interactive = true)
        require("TNA_XHTTP_DELETED" in deleted.stdout || "TNA_XHTTP_NOT_INSTALLED" in deleted.stdout) { "04f deletion marker missing" }
        log("PNA_CDN_MANAGED_COMPONENTS_REMOVED=1")
    }

    private data class CdnInputPaths(val tempPath: String, val runtimePath: String)

    private suspend fun cdnInputPaths(handle: SshHandle, domain: String, email: String, publicIp: String): CdnInputPaths {
        val token = randomToken()
        val tempName = "proxy-node-assistant-cdn-manual-$token.env"
        val tempPath = "/tmp/$tempName"
        val runtimePath = "/root/.config/proxy-node-assistant/runtime-input/cdn-manual-$token.env"
        val body = buildString {
            appendLine("TNA_CDN_ROUTE_INPUT_VERSION=1")
            appendLine("ROUTE_MODE_B64=${b64("orange")}")
            appendLine("PUBLIC_IPV4_B64=${b64(publicIp)}")
            appendLine("ORANGE_DOMAIN_B64=${b64(domain)}")
            appendLine("ORANGE_EMAIL_B64=${b64(email)}")
            appendLine("GRAY_DOMAIN_B64=${b64("")}")
        }
        handle.upload(body.toByteArray(), tempName, "/tmp", "0600")
        checked(
            handle,
            "install -d -m 700 /root/.config/proxy-node-assistant/runtime-input; install -o root -g root -m 600 ${SshHandle.shellQuote(tempPath)} ${SshHandle.shellQuote(runtimePath)}; rm -f -- ${SshHandle.shellQuote(tempPath)}",
            emit = false,
        )
        return CdnInputPaths(tempPath, runtimePath)
    }

    private suspend fun cdnPublicIp(handle: SshHandle): String {
        val result = checked(
            handle,
            "ip=\$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true); [ -n \"\$ip\" ] || ip=\$(hostname -I | awk '{print \$1}'); printf '%s\\n' \"\$ip\"",
            emit = false,
        )
        return result.stdout.lines().map { it.trim() }.firstOrNull { ProtocolParsers.validCanonicalPublicIpv4(it) }
            ?: error(tr("无法确定 VPS 公网 IPv4", "Could not determine the VPS public IPv4"))
    }

    private fun verifyDirectOriginBlocked(publicIp: String) {
        val reachable = runCatching {
            Socket().use { socket -> socket.connect(InetSocketAddress(publicIp, 8443), 5_000) }
        }.isSuccess
        check(!reachable) {
            tr("外部设备仍能直连源站 8443，拒绝宣称已锁源", "This device can still reach origin 8443 directly; the Cloudflare-only lock cannot be claimed")
        }
    }

    private fun verifyCloudflareEdge(domain: String, port: Int) {
        require(Validation.validDomain(domain) && port in 1..65535)
        val connection = URL("https://$domain:$port/").openConnection(Proxy.NO_PROXY) as HttpsURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 30_000
        connection.instanceFollowRedirects = true
        connection.requestMethod = "GET"
        try {
            val status = connection.responseCode
            check(status in 200..399) { "Cloudflare edge returned HTTP $status" }
            check(!connection.getHeaderField("Cf-Ray").isNullOrBlank()) { "Cloudflare edge response is missing Cf-Ray" }
            // v0.9.5 nginx emits X-TNA-* headers; v1 emits the product-neutral
            // X-PNA-* aliases.  Accept either exact marker while remaining
            // fail-closed for missing or unexpected values.
            val managedOrigin = sequenceOf(
                connection.getHeaderField("X-PNA-Managed-Origin"),
                connection.getHeaderField("X-TNA-Managed-Origin"),
            ).mapNotNull { it?.trim() }.firstOrNull { it == "cdn-xhttp-v095" }
            val originPort = sequenceOf(
                connection.getHeaderField("X-PNA-Origin-Port"),
                connection.getHeaderField("X-TNA-Origin-Port"),
            ).mapNotNull { it?.trim() }.firstOrNull { it == "8443" }
            check(managedOrigin != null) { "managed CDN origin marker is missing" }
            check(originPort != null) { "origin port marker is missing" }
        } finally {
            connection.disconnect()
        }
    }

    /** Roll back only managed CDN state and return true only with readback evidence. */
    private suspend fun rollbackCdnPublic(handle: SshHandle, removeStage: Boolean, removeLock: Boolean, resetEdge: Boolean): Boolean {
        var ok = true
        suspend fun runOptional(command: String, tolerate: (String) -> Boolean = { false }): RemoteResult? {
            val result = runCatching { handle.exec(command, root = true, log = { }) }.getOrNull() ?: run { ok = false; return null }
            if (!result.ok && !tolerate(result.stdout + "\n" + result.stderr)) ok = false
            return result
        }
        if (removeStage) {
            runOptional("bash $REMOTE_ROOT/linux/05e-cdn-xhttp-nginx.sh disable-stage") { text -> "TNA_CDN_STAGE_NOT_INSTALLED" in text || "TNA_CDN_NGINX_ERROR=UNMANAGED_STAGE_CONFIG" in text }
        }
        if (removeLock) runOptional("bash $REMOTE_ROOT/linux/05f-cloudflare-origin-lock.sh remove")
        if (resetEdge) runOptional("bash $REMOTE_ROOT/linux/05g-cdn-xhttp-validate.sh --reset")
        // A loopback XHTTP inbound is intentionally retained after public
        // rollback.  Check only non-loopback listeners; treating 127.0.0.1 /
        // 127.0.0.2 as a public leak would make every safe rollback report a
        // failure and would tempt callers to delete the useful shadow.
        val listener = runOptional(
            "! ss -H -lnt 2>/dev/null | awk '\$4 ~ /:8443$/ && \$4 !~ /^127\\.0\\.0\\.1:8443$/ && \$4 !~ /^127\\.0\\.0\\.2:8443$/ && \$4 !~ /^\\[::1\\]:8443$/ {found=1} END{exit found ? 0 : 1}'",
        )
        if (listener == null || !listener.ok) ok = false
        if (ok) log("CDN_PUBLIC_ORIGIN_ROLLED_BACK=1 TNA_CDN_EDGE_STATE_RESET=1") else log("CDN_PUBLIC_ORIGIN_ROLLED_BACK=FAILED")
        return ok
    }

    private suspend fun readStableNodeIdentity(handle: SshHandle): StableNodeIdentity {
        val command = """
            set -u
            root=$REMOTE_ROOT
            [ -x "${'$'}root/linux/23-node-identity.sh" ] || root=$LEGACY_TEXT_REMOTE_ROOT
            [ -x "${'$'}root/linux/23-node-identity.sh" ] || root=$LEGACY_REMOTE_ROOT
            [ -x "${'$'}root/linux/23-node-identity.sh" ] || { echo TNA_NODE_IDENTITY_ERROR=SCRIPT_MISSING >&2; exit 62; }
            bash "${'$'}root/linux/23-node-identity.sh" --show
        """.trimIndent()
        return ProtocolParsers.stableNodeIdentity(checked(handle, command, emit = false).stdout, handle.target.id)
    }

    private suspend fun syncStableNodeIdentity(handle: SshHandle) {
        val repository = stableNodes ?: return
        runCatching { readStableNodeIdentity(handle) }.onSuccess(repository::put)
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
        val addresses = InetAddress.getAllByName(domain).mapNotNull { (it as? Inet4Address)?.hostAddress }.distinct()
        addresses.isNotEmpty() && addresses.all { it == ip }
    }.getOrDefault(false)

    /**
     * Safely rebind an existing VPS after a public-IP change.  The old
     * endpoint's key and host-key pin are required; no new identity is minted.
     */
    private suspend fun rebindPublicIp(oldTarget: NodeTarget): SshHandle? {
        val keyRepo = requireNotNull(managedKeys) { "LOCAL_KEY_RECORD_NOT_FOUND" }
        val hostRepo = requireNotNull(hostKeys) { "LOCAL_HOST_KEY_RECORD_NOT_FOUND" }
        val identityRepo = requireNotNull(stableNodes) { "LOCAL_NODE_IDENTITY_STORE_UNAVAILABLE" }
        check(keyRepo.get(oldTarget.id) != null) { "LOCAL_KEY_RECORD_NOT_FOUND" }
        check(hostRepo.get(oldTarget.id) != null) { "LOCAL_HOST_KEY_RECORD_NOT_FOUND" }

        // Older v1 installs may not have been visited since node identity was
        // introduced.  Seed the local binding by reading the remote identity
        // over the old, already pinned endpoint; this does not enroll a device.
        val expected = identityRepo.get(oldTarget.id) ?: run {
            val oldHandle = ssh.connect(oldTarget, SessionCredential(AuthMode.MANAGED_KEY), language)
            try {
                readStableNodeIdentity(oldHandle).also(identityRepo::put)
            } finally {
                oldHandle.close()
            }
        }

        val newIp = required(
            tr("新公网 IPv4", "New public IPv4"),
            tr("输入服务商已经分配给同一 VPS 的新公网 IPv4", "Enter the new public IPv4 already assigned to the same VPS"),
        ) { ProtocolParsers.validCanonicalPublicIpv4(it) }
        check(newIp != expected.currentPublicIp) { tr("新 IP 与旧 IP 相同，没有重绑定动作可做", "The new IP equals the old IP; there is nothing to rebind") }
        val newPort = required(
            tr("新 SSH 端口", "New SSH port"),
            tr("默认沿用旧端口；可输入新端口", "Keep the old port by default, or enter a new port"),
            oldTarget.port.toString(),
        ) { it.toIntOrNull()?.let { port -> port in 1..65535 } == true }.toInt()
        val newTarget = NodeTarget(newIp, oldTarget.user, newPort, oldTarget.label)

        val session = runCatching { ssh.connectRebound(oldTarget, newTarget, null, language) }.getOrElse { first ->
            check(first.message?.contains("PUBLICKEY_REJECTED") == true) { throw first }
            val password = prompts.ask(
                tr("当前 VPS 密码", "Current VPS password"),
                tr("Host Key 已匹配但旧 key 被拒绝。密码只用于本次认证并重新安装同一公钥，不会保存或生成新 key。", "The host key matched but the old key was rejected. The password is used only for this authentication and reinstalling the same public key; it is not saved or used to generate a new key."),
                PromptKind.SECRET,
            )
            ssh.connectRebound(oldTarget, newTarget, password, language)
        }
        val handle = session.handle
        try {
            if (session.usedPasswordFallback) {
                val original = requireNotNull(keyRepo.get(oldTarget.id))
                installPublicKey(handle, original.publicKeyOpenSsh)
            }
            val actual = readStableNodeIdentity(handle)
            check(sameStableNode(expected, actual) && actual.currentPublicIp == expected.currentPublicIp) {
                "IP_REBIND_BLOCKED_PRE_DNS: NODE_ID/SERVER_ID/machine-id/host-key mismatch"
            }
            val exactProbe = probe(handle)
            check(exactProbe.installed && exactProbe.complete && exactProbe.version == VERSION && exactProbe.buildId == BUILD_ID && exactProbe.buildRevision == BUILD_REVISION) {
                "IP_REBIND_BLOCKED_PRE_DNS: toolkit build mismatch"
            }
            val publicEnv = ProtocolParsers.kv(
                checked(handle, "cat /etc/proxy-runbook/public.env 2>/dev/null; cat /etc/text-node-assistant/public.env 2>/dev/null", emit = false).stdout,
            )
            val oldDomain = publicEnv["COVER_DOMAIN"].orEmpty().lowercase(Locale.ROOT)
            check(Validation.validDomain(oldDomain)) { "IP_REBIND_BLOCKED_PRE_DNS: invalid managed construction domain" }
            val newDomain = required(
                tr("新施工域名", "New construction domain"),
                tr("直接确认表示保留原域名；更换域名会停在 Cloudflare 人工阶段", "Keep the default to retain the domain; changing it stops at the Cloudflare manual phase"),
                oldDomain,
            ) { Validation.validDomain(it) }.lowercase(Locale.ROOT)
            val args = listOf(expected.currentPublicIp, newIp, oldDomain, newDomain).joinToString(" ") { SshHandle.shellQuote(it) }
            val preflight = checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh preflight $args", emit = false)
            val preflightPayload = ProtocolParsers.markedBlockCurrentOrLegacy(
                preflight.stdout,
                "__PNA_IP_REBIND_PREFLIGHT_V1_BEGIN__",
                "__PNA_IP_REBIND_PREFLIGHT_V1_END__",
                "__TNA_IP_REBIND_PREFLIGHT_V1_BEGIN__",
                "__TNA_IP_REBIND_PREFLIGHT_V1_END__",
            )
            val values = ProtocolParsers.kv(preflightPayload)
            check(
                values["IP_REBIND_STATUS"] == "IP_REBIND_PREPARED" && values["SERVER_ID_MATCH"] == "1" &&
                    values["NODE_ID_UNCHANGED"] == "1" && values["MACHINE_ID_MATCH"] == "1" &&
                    values["REMOTE_PUBLIC_IP_MATCH"] == "1" && values["DNS_MUTATED"] == "0" &&
                    values["CLOUDFLARE_MUTATION"] == "NONE",
            ) { "IP_REBIND_BLOCKED_PRE_DNS: invalid preflight protocol" }
            log(preflight.stdout.trim())

            val direct = (values["DEPLOYMENT_MODE"] == "direct-reality" && values["ACTIVE_MODE"] == "ACTIVE_DIRECT") ||
                (values["DEPLOYMENT_MODE"] == "dual-hot-switch" && values["ACTIVE_MODE"] == "DUAL_INSTALLED_ACTIVE_DIRECT")
            if (!direct || newDomain != oldDomain) {
                val wait = checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh wait-cloudflare $args", emit = false)
                check("WAITING_FOR_CLOUDFLARE_MANUAL_ACTION" in wait.stdout)
                log("CLOUDFLARE_DASHBOARD_OPENED=${openCloudflareDnsDashboard()}")
                throw CancellationException(tr("事务已安全停在 Cloudflare 人工确认阶段；本机 key endpoint 尚未提交。", "The transaction is safely parked for Cloudflare manual validation; the local key endpoint is not committed."))
            }
            log("CLOUDFLARE_DASHBOARD_OPENED=${openCloudflareDnsDashboard()}")
            while (!directDnsMatches(newDomain, newIp)) {
                val answer = prompts.ask(
                    tr("等待 DNS", "Waiting for DNS"),
                    tr("把 A 记录改为新 IP 并保持 DNS only。按 Enter 重检，输入 q 在 DNS 前安全停止。", "Update the A record to the new IP and keep DNS only. Press Enter to retry, or q to stop safely before DNS."),
                    PromptKind.TEXT,
                )
                if (answer.trim().equals("q", true)) {
                    runCatching { checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh abort-pre-dns", emit = false) }
                    throw CancellationException("IP_REBIND_ABORTED_PRE_DNS")
                }
            }
            val commit = checked(handle, "bash $REMOTE_ROOT/linux/27-ip-rebind.sh commit-direct $args", emit = false)
            check("IP_REBIND_STATUS=IP_REBIND_COMPLETE" in commit.stdout) { "IP_REBIND_BLOCKED_POST_DNS" }
            val committedIdentity = readStableNodeIdentity(handle)
            check(sameStableNode(expected, committedIdentity) && committedIdentity.currentPublicIp == newIp) {
                "IP_REBIND_BLOCKED_POST_DNS: identity readback failed"
            }
            check(keyRepo.rebind(oldTarget.id, newTarget.id)) { "IP_REBIND_BLOCKED_POST_DNS: local managed-key endpoint commit failed" }
            hostRepo.commitRebind(oldTarget.id, session.presentedHostKey)
            identityRepo.rebind(oldTarget.id, committedIdentity)
            targets.remember(newTarget)
            log(commit.stdout.trim())
            log("SSH_AUTH_KEY_ID_UNCHANGED=1")
            showHandoff(handle)
            return handle
        } catch (error: Throwable) {
            runCatching { handle.close() }
            throw error
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

    private suspend fun updateToolkitOnly(handle: SshHandle, reason: String) {
        val apply = prompts.ask(
            tr("仅更新内嵌工具包", "Update embedded toolkit only"),
            tr(
                "检测到$reason。此次只替换远端 ProxyNodeAssistant 工具包，不收集路线、凭据或面板设置，也不运行全量安装器。输入大写 APPLY 才继续。",
                "Detected $reason. This run replaces only the remote ProxyNodeAssistant toolkit; it does not collect route, credential, or panel settings and does not run the full installer. Type uppercase APPLY to continue.",
            ),
            PromptKind.EXACT_CONFIRMATION,
            placeholder = "APPLY",
            danger = true,
        ).trim()
        if (apply != "APPLY") throw CancellationException("toolkit-only update not applied")
        log("TOOLKIT_ONLY_UPDATE_CONFIRMED")
        recoverInterruptedInstallTransaction(handle)
        uploadToolkit(handle)
        val verified = probe(handle)
        check(verified.installed && verified.complete && verified.version == VERSION && verified.buildId == BUILD_ID && verified.buildRevision == BUILD_REVISION) {
            "toolkit-only update returned, but the exact v$VERSION build probe is missing"
        }
        log("TOOLKIT_ONLY_UPDATE_COMPLETE")
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
              brand='PNA'
              [ "${'$'}root" = "$LEGACY_TEXT_REMOTE_ROOT" ] && brand='TNA_LEGACY'
              [ "${'$'}root" = "$LEGACY_REMOTE_ROOT" ] && brand='PNA_LEGACY'
                complete=0
                # The Android client still exposes the complete v0.9.5
                # non-storage surface (backup, credential handoff, Reality,
                # CDN/XHTTP, subscription, diagnostics, security, traffic,
                # identity and rollback). Keep this list aligned with the
                # desktop probe contract. The retirement helper is retained
                # only as a migration cleanup primitive; active storage and
                # admission entry points are deliberately not required.
                if test -x "${'$'}root/linux/00-bootstrap-toolkit.sh" &&
                   test -x "${'$'}root/linux/00-preflight-vps.sh" &&
                   test -x "${'$'}root/linux/00-migrate-legacy-state.sh" &&
                   test -x "${'$'}root/linux/00-auto-install-or-optimize.sh" &&
                   # This one-shot helper only retires old v0.9.x state; it is
                   # not an active storage or admission feature.
                   test -x "${'$'}root/linux/00c-retire-v095-device-drive.sh" &&
                   test -x "${'$'}root/linux/01-safe-backup.sh" &&
                   test -x "${'$'}root/linux/01a-rotate-vps-password.sh" &&
                   test -x "${'$'}root/linux/02-install-base.sh" &&
                   test -x "${'$'}root/linux/02b-firewall-safe.sh" &&
                   test -x "${'$'}root/linux/03-install-3xui.sh" &&
                   test -x "${'$'}root/linux/03b-lockdown-panel.sh" &&
                   test -x "${'$'}root/linux/03c-rotate-panel-credentials.sh" &&
                   test -x "${'$'}root/linux/03d-export-panel-handoff.sh" &&
                   test -x "${'$'}root/linux/04-generate-reality.sh" &&
                   test -x "${'$'}root/linux/04a-reality-api.sh" &&
                   test -x "${'$'}root/linux/04b-open-test-port-current-ssh.sh" &&
                   test -x "${'$'}root/linux/04c-close-test-port.sh" &&
                   test -x "${'$'}root/linux/04d-optimize-existing-reality-shadow.sh" &&
                   test -x "${'$'}root/linux/04e-export-reality-handoff.sh" &&
                   test -x "${'$'}root/linux/04f-xhttp-cdn-api.sh" &&
                   test -x "${'$'}root/linux/05-cover-bootstrap.sh" &&
                   test -x "${'$'}root/linux/05a-cloudflare-dns-upsert.sh" &&
                   test -x "${'$'}root/linux/05b-cover-site-polished.sh" &&
                   test -x "${'$'}root/linux/05c-optimize-cover-backend.sh" &&
                   test -x "${'$'}root/linux/05d-configure-subscription.sh" &&
                   test -x "${'$'}root/linux/05e-cdn-xhttp-nginx.sh" &&
                   test -x "${'$'}root/linux/05f-cloudflare-origin-lock.sh" &&
                   test -x "${'$'}root/linux/05g-cdn-xhttp-validate.sh" &&
                   test -x "${'$'}root/linux/05h-ensure-cdn-certificate.sh" &&
                   test -x "${'$'}root/linux/06-warp-install.sh" &&
                   test -x "${'$'}root/linux/07-warp-configure-proxy.sh" &&
                   test -x "${'$'}root/linux/07a-apply-warp-route-local.sh" &&
                   test -x "${'$'}root/linux/08-warp-check.sh" &&
                   test -x "${'$'}root/linux/09-status-node.sh" &&
                   test -x "${'$'}root/linux/10-emergency-network-dump.sh" &&
                   test -x "${'$'}root/linux/11-safe-upgrade-audit.sh" &&
                   test -x "${'$'}root/linux/12-restore-iptables-vnc-only.sh" &&
                   test -x "${'$'}root/linux/13-maintenance-menu.sh" &&
                   test -x "${'$'}root/linux/14-node-doctor.sh" &&
                   test -x "${'$'}root/linux/15-show-current-node.sh" &&
                   test -x "${'$'}root/linux/16-auto-diagnose.sh" &&
                   test -x "${'$'}root/linux/17-safe-auto-repair.sh" &&
                   test -x "${'$'}root/linux/18-panel-metadata.sh" &&
                   test -x "${'$'}root/linux/19-prune-backups-current-config.sh" &&
                   test -x "${'$'}root/linux/20-adaptive-performance.sh" &&
                   test -x "${'$'}root/linux/21-traffic-status.sh" &&
                   test -x "${'$'}root/linux/22-dismantle-managed-node.sh" &&
                   test -x "${'$'}root/linux/23-node-identity.sh" &&
                   test -x "${'$'}root/linux/23-ss2022-tcp.sh" &&
                   test -x "${'$'}root/linux/24-security-baseline.sh" &&
                   test -x "${'$'}root/linux/25-security-events.sh" &&
                   test -x "${'$'}root/linux/27-ip-rebind.sh" &&
                   test -x "${'$'}root/linux/28-topology-reconcile.sh" &&
                   test -x "${'$'}root/linux/28a-install-transaction.sh" &&
                   test -s "${'$'}root/linux/32-subscription-rewrite.py" &&
                   test -x "${'$'}root/linux/lib-deployment-state.sh" &&
                   test -x "${'$'}root/linux/lib-dns-quorum.sh" &&
                   test -x "${'$'}root/linux/lib-gui-prompt.sh" &&
                   test -x "${'$'}root/linux/lib-handoff.sh" &&
                   test -x "${'$'}root/linux/lib-third-party.sh" &&
                   test -x "${'$'}root/linux/lib-xui-api.sh" &&
                   test -s "${'$'}root/templates/cover-sites/MANIFEST.tsv" &&
                   test -s "${'$'}root/templates/cover-sites/15-signal-runner.html" &&
                   test -s "${'$'}root/TOOLKIT_BUILD_ID" &&
                   test -s "${'$'}root/TOOLKIT_BUILD_REVISION"; then
                  complete=1
                fi
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
        check(probe.complete) { tr("远端工具包不完整；请运行菜单 [1]，在 APPLY 确认后原位修复", "Remote toolkit is incomplete; run action 1 and confirm APPLY for an in-place repair") }
        check(probe.version == VERSION) { tr("远端工具包 v${probe.version} 与 Android 客户端 v$VERSION 不匹配；升级时执行 [1]，否则使用同版客户端", "Remote toolkit v${probe.version} does not match Android client v$VERSION; run action 1 when upgrading, or use a matching client") }
        check(probe.buildRevision == BUILD_REVISION && probe.buildId == BUILD_ID) { tr("远端 v$VERSION 构建不匹配；旧构建请执行 [1] 更新，更新构建请换新版客户端", "Remote v$VERSION build does not match; run action 1 to update an older build, or use a newer client") }
    }

    private suspend fun showHandoff(handle: SshHandle) {
        // Prefer the renamed product directory but retain the v0.9.x paths as
        // read-only migration sources.  The wrapper markers are product
        // neutral so either generation can be parsed without printing shell
        // diagnostics into the handoff payload.
        // Read all compatibility roots and their archives in chronological order.
        // Compatibility roots are emitted first and the canonical
        // proxy-runbook root last.  loginCredentialForm() is last-usable-value
        // wins, so the active v1 store cannot be shadowed by stale migration
        // values from a v0.9.x or early product-named root.
        // A v0.9.x upgrade can leave the current proxy-runbook file present
        // but incomplete while the usable credentials still live in the
        // legacy root/archive; an if/else here would strand that handoff.
        val command = """
            printf '%s\n' '${ProtocolParsers.HANDOFF_BEGIN}'
            # CURRENT-LOGIN-CREDENTIALS.env is a protected key/value store,
            # not a complete handoff document and therefore has no run marker.
            # Add a transport-local marker so a store-only recovery can still
            # be rendered; this marker carries no credential material.
            printf 'HANDOFF_RUN_STARTED=android-read-only-export\n'
            emit_file() {
                file="${'$'}1"
                [ -r "${'$'}file" ] || return 0
                # A stored handoff may itself contain a complete marker block.
                # Strip nested PNA/TNA markers before concatenation so the
                # outer transport marker remains unambiguous.  Raw files are
                # left unchanged for legacy recovery/audit.
                awk '!/^[[:space:]]*__(PNA|TNA)_HANDOFF_(BEGIN|END)__[[:space:]]*${'$'}/' "${'$'}file"
            }
            emit_archive() {
                dir="${'$'}1"
                [ -d "${'$'}dir" ] || return 0
                find "${'$'}dir" -maxdepth 1 -type f -name 'HANDOFF-*.txt' -printf '%T@ %p\n' 2>/dev/null |
                    sort -n |
                    while IFS= read -r entry; do
                        file="${'$'}{entry#* }"
                        [ -f "${'$'}file" ] && emit_file "${'$'}file"
                    done
            }
            emit_archive /root/.config/text-node-assistant/handoff-archive
            [ -r /root/.config/text-node-assistant/HANDOFF-SECRETS.txt ] && emit_file /root/.config/text-node-assistant/HANDOFF-SECRETS.txt || true
            [ -r /root/.config/text-node-assistant/CURRENT-LOGIN-CREDENTIALS.env ] && emit_file /root/.config/text-node-assistant/CURRENT-LOGIN-CREDENTIALS.env || true
            emit_archive /root/.config/proxy-node-assistant/handoff-archive
            [ -r /root/.config/proxy-node-assistant/HANDOFF-SECRETS.txt ] && emit_file /root/.config/proxy-node-assistant/HANDOFF-SECRETS.txt || true
            [ -r /root/.config/proxy-node-assistant/CURRENT-LOGIN-CREDENTIALS.env ] && emit_file /root/.config/proxy-node-assistant/CURRENT-LOGIN-CREDENTIALS.env || true
            emit_archive /root/.config/proxy-runbook/handoff-archive
            [ -r /root/.config/proxy-runbook/HANDOFF-SECRETS.txt ] && emit_file /root/.config/proxy-runbook/HANDOFF-SECRETS.txt || true
            [ -r /root/.config/proxy-runbook/CURRENT-LOGIN-CREDENTIALS.env ] && emit_file /root/.config/proxy-runbook/CURRENT-LOGIN-CREDENTIALS.env || true
            printf '%s\n' '${ProtocolParsers.HANDOFF_END}'
        """.trimIndent()
        val result = checked(handle, command, emit = false)
        val legacy = ProtocolParsers.handoff(result.stdout)
        // A handoff is useful only when the four login fields are complete.
        // Do not silently downgrade to a partial/key-only block: callers need
        // an actionable credential bundle for a new client or recovery path.
        val login = ProtocolParsers.loginCredentialForm(legacy)
        val fields = linkedMapOf<String, String>()
        fields["PNA_VERSION"] = VERSION
        fields["VPS_SSH_USER"] = handle.target.user
        fields["VPS_SSH_PORT"] = handle.target.port.toString()
        fields["VPS_PASSWORD_STATUS"] = "PRESENT_IN_PROTECTED_HANDOFF"
        fields["FORM_VPS_ACCOUNT"] = login.getValue("FORM_VPS_ACCOUNT")
        fields["FORM_VPS_PASSWORD"] = login.getValue("FORM_VPS_PASSWORD")
        fields["FORM_PANEL_ACCOUNT"] = login.getValue("FORM_PANEL_ACCOUNT")
        fields["FORM_PANEL_PASSWORD"] = login.getValue("FORM_PANEL_PASSWORD")
        val boundKey = managedKeys.get(handle.target.id)
        fields["SSH_AUTH_MODE"] = if (boundKey != null) "MANAGED_KEY" else "TEMPORARY_PASSWORD_ONE_RUN"
        fields["SSH_KEY_ONLY"] = (boundKey != null).toString()
        boundKey?.let {
            fields["SSH_PRIVATE_KEY_STORAGE"] = "ANDROID_KEYSTORE_ENCRYPTED_APP_PRIVATE"
            fields["SSH_AUTH_KEY_ID"] = sshAuthenticationKeyId(it.publicKeyOpenSsh)
        }
        // Preserve the complete non-storage handoff surface from v0.9.5.
        // Links and subscription URLs are secrets in practice, so they are
        // copied only into the protected handoff panel, never the ordinary
        // workflow log.  CDN links are accepted only after strict parsing;
        // malformed or placeholder values are omitted rather than surfaced as
        // usable credentials.
        // Keep the v0.9.5 protocol surface, but copy only fields that pass the
        // typed allowlist/validators.  The raw stream is archive -> current;
        // scan it in that order and retain the last *valid* occurrence rather
        // than using kv()'s last-line-wins map, because an interrupted current
        // run may append an empty/malformed value over a usable archive value.
        // completeHandoff performs the same pass at its final rendering
        // boundary, so direct callers and this workflow cannot diverge.
        fields.putAll(ProtocolParsers.validatedHandoffProtocolFieldsFromRaw(legacy))
        runCatching {
            ProtocolParsers.kv(checked(handle, "cat /etc/proxy-runbook/public.env 2>/dev/null; cat /etc/text-node-assistant/public.env 2>/dev/null", emit = false).stdout)
        }.getOrNull()?.let { runtime ->
            runtime["PUBLIC_IP"]?.takeIf(ProtocolParsers::validCanonicalPublicIpv4)?.let { fields["VPS_PUBLIC_IP"] = it }
            runtime["COVER_DOMAIN"]?.takeIf(Validation::validDomain)?.let { fields["CONSTRUCTION_DOMAIN"] = it.lowercase(Locale.ROOT) }
            runtime["SS2022_PORT"]?.toIntOrNull()?.takeIf(Ss2022PortPolicy::valid)?.let { fields["SS2022_PORT"] = it.toString() }
        }
        runCatching {
            ProtocolParsers.kv(checked(handle, "cat /etc/proxy-runbook/deployment-state.env 2>/dev/null; cat /etc/text-node-assistant/deployment-state.env 2>/dev/null", emit = false).stdout)
        }.getOrNull()?.let { deployment ->
            deployment["DEPLOYMENT_MODE"]?.takeIf { it.isNotBlank() }?.let { fields["DEPLOYMENT_MODE"] = it }
            deployment["ACTIVE_MODE"]?.takeIf { it.isNotBlank() }?.let { fields["ACTIVE_MODE"] = it }
            deployment["ORIGIN_HISTORY"]?.takeIf { it.isNotBlank() }?.let { fields["ORIGIN_HISTORY"] = it.replace(Regex("\\s+"), " ").take(240) }
            val mode = deployment["DEPLOYMENT_MODE"].orEmpty()
            val active = deployment["ACTIVE_MODE"].orEmpty()
            fields["V095_CDN_STATUS"] = if (mode == "direct-reality") "NOT_CONFIGURED" else active.ifBlank { "UNKNOWN" }
            fields["V095_PHASE_STATUS"] = if (mode == "direct-reality") "DIRECT_COMPATIBILITY_BASELINE" else "STAGED_ROUTE_RECONCILED"
        }
        // Include only non-secret CDN/topology state in the protected
        // handoff.  Both product and legacy paths are read so an upgrade can
        // still expose the v0.9.5 three-protocol route without moving secrets
        // into ordinary logs.
        runCatching {
            ProtocolParsers.kv(
                checked(
                    handle,
                    "cat /root/.config/proxy-node-assistant/topology.env 2>/dev/null; " +
                        "cat /root/.config/text-node-assistant/topology.env 2>/dev/null; " +
                        "cat /etc/proxy-runbook/topology.env 2>/dev/null; " +
                        "cat /etc/text-node-assistant/topology.env 2>/dev/null; " +
                        "cat /etc/proxy-runbook/cloudflare/edge-state.env 2>/dev/null; " +
                        "cat /etc/text-node-assistant/cloudflare/edge-state.env 2>/dev/null",
                    emit = false,
                ).stdout,
            )
        }.getOrNull()?.let { topology ->
            listOf(
                "TOPOLOGY_MODE", "ROUTE_MODE", "ACTIVE_MODE", "ORANGE_DOMAIN", "GRAY_DOMAIN",
                "CDN_EDGE_DOMAIN", "CDN_EDGE_PORT", "CDN_ORIGIN_PORT", "CDN_EDGE_VALIDATED",
                "CDN_CLIENT_CONFIRMED", "CDN_ORIGIN_READY", "CDN_ORIGIN_SCOPE", "TNA_TOPOLOGY_RECONCILED",
            ).forEach { key -> topology[key]?.trim()?.takeIf { it.isNotBlank() && it.length <= 512 }?.let { fields[key] = it } }
        }
        runCatching { readStableNodeIdentity(handle) }.getOrNull()?.let { identity ->
            fields["SERVER_ID"] = identity.serverId
            fields["NODE_ID"] = identity.nodeId
            fields["MACHINE_ID_SHA256"] = identity.machineIdSha256
            fields["SSH_HOST_KEY_SHA256"] = identity.hostKeySha256
            fields["FIRST_KNOWN_PUBLIC_IP"] = identity.firstKnownPublicIp
            fields["CURRENT_PUBLIC_IP"] = identity.currentPublicIp
        }
        runCatching { ProtocolParsers.panel(checked(handle, panelMetadataCommand(), emit = false).stdout) }.getOrNull()?.let { panel ->
            fields["PANEL_REMOTE_LOOPBACK_PORT"] = panel.port.toString()
            fields["PANEL_LOCAL_URL_TEMPLATE"] = "http://127.0.0.1:<LOCAL_TUNNEL_PORT>${panel.path}"
            fields["PANEL_SSH_TUNNEL_INSTRUCTION"] = "Use Android operation 2; the application creates a localhost SSH tunnel."
            fields["FORM_PANEL_LOCAL_URL"] = "http://127.0.0.1:<LOCAL_TUNNEL_PORT>${panel.path}"
        }
        val handoff = ProtocolParsers.completeHandoff(legacy, fields)
        _state.update { it.copy(secretHandoff = handoff) }
        log("CREDENTIAL_HANDOFF_VALIDATED; secrets are shown only in the protected handoff panel")
    }

    /**
     * Resolve panel metadata from the current toolkit first, then the two
     * v0.9.x roots kept for in-place upgrades.  The probe is read-only and
     * fails explicitly when none of the roots contains the script, rather
     * than silently presenting a handoff without a usable panel URL.
     */
    private fun panelMetadataCommand(): String = """
        set -u
        root='$REMOTE_ROOT'
        [ -x "${'$'}root/linux/18-panel-metadata.sh" ] || root='$LEGACY_TEXT_REMOTE_ROOT'
        [ -x "${'$'}root/linux/18-panel-metadata.sh" ] || root='$LEGACY_REMOTE_ROOT'
        [ -x "${'$'}root/linux/18-panel-metadata.sh" ] || {
            echo PANEL_METADATA_ERROR=SCRIPT_MISSING >&2
            exit 12
        }
        bash "${'$'}root/linux/18-panel-metadata.sh"
    """.trimIndent()

    private fun sshAuthenticationKeyId(publicKey: String): String {
        val fields = publicKey.trim().split(Regex("\\s+"))
        require(fields.size >= 2 && fields[0] == "ssh-ed25519") { "unsupported managed SSH public key" }
        val blob = Base64.decode(fields[1], Base64.DEFAULT)
        require(blob.size >= 32) { "invalid managed SSH public key" }
        return "SHA256:" + Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(blob), Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private suspend fun openPanel(handle: SshHandle): Boolean {
        ensureToolkit(handle)
        val meta = ProtocolParsers.panel(checked(handle, panelMetadataCommand(), emit = false).stdout)
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
        val mode = chooseCredentialMutationMode(
            tr("VPS 登录密码策略", "VPS login password policy"),
            tr("选择生成新的高强度随机密码，或手动输入一个自定义密码。自定义值只进入一次性 root-only 文件。", "Choose a new high-entropy random password or enter a custom one. Custom values travel only in a one-run root-only file."),
        ) ?: return
        val customPassword = if (mode == InstallCredentialMode.CUSTOM) {
            matchingSecret(
                tr("自定义 VPS 登录密码", "Custom VPS login password"),
                tr("输入 8—256 个字符；空格有意义，不写日志或设置。", "Enter 8-256 characters; spaces are meaningful and the value is never logged or persisted."),
            )
        } else ""
        val confirmMessage = if (mode == InstallCredentialMode.CUSTOM) {
            tr("确认立即写入 $user 的自定义登录密码？SSH key 已存在，不会因此失联。", "Apply the custom login password for $user now? The existing SSH key prevents lockout.")
        } else {
            tr("为 $user 生成并立即应用高强度随机密码？SSH key 已存在，不会因此失联。", "Generate and immediately apply a high-entropy random password for $user? The existing SSH key prevents lockout.")
        }
        if (!confirmYes(confirmMessage, false)) return
        var inputPath: String? = null
        try {
            if (mode == InstallCredentialMode.CUSTOM) {
                inputPath = writeOneRunInput(handle, "VPS_PASSWORD_B64=${b64(customPassword)}\n", "credential-input")
            }
            val env = buildString {
                append("PNA_VPS_PASSWORD_MODE=")
                append(SshHandle.shellQuote(mode.wireValue))
                val path = inputPath
                if (path != null) {
                    append(" PNA_CREDENTIAL_INPUT=")
                    append(SshHandle.shellQuote(path))
                }
            }
            checked(handle, "source $REMOTE_ROOT/linux/lib-handoff.sh; handoff_begin_run; $env bash $REMOTE_ROOT/linux/01a-rotate-vps-password.sh ${SshHandle.shellQuote(user)}")
        } finally {
            inputPath?.let { path -> withContext(NonCancellable) { removeOneRunInput(handle, path) } }
        }
        showHandoff(handle)
    }

    private suspend fun rotatePanelCredentials(handle: SshHandle) {
        val mode = chooseCredentialMutationMode(
            tr("3x-ui 面板凭据策略", "3x-ui panel credential policy"),
            tr("选择生成新的随机账号/密码，或手动输入自定义值。自定义秘密只进入一次性 root-only 文件。", "Choose new random panel credentials or enter custom values. Custom secrets travel only in a one-run root-only file."),
        ) ?: return
        var customAccount = ""
        var customPassword = ""
        if (mode == InstallCredentialMode.CUSTOM) {
            customAccount = required(
                tr("自定义 3x-ui 面板账号", "Custom 3x-ui panel username"),
                tr("仅允许字母、数字、下划线、点和连字符；首字符必须是字母或下划线。", "Letters, digits, underscore, dot, and hyphen only; start with a letter or underscore."),
            ) { AndroidCredentialPlan.validPanelAccount(it) }
            customPassword = matchingSecret(
                tr("自定义 3x-ui 面板密码", "Custom 3x-ui panel password"),
                tr("输入 8—256 个字符；空格有意义，不写日志或设置。", "Enter 8-256 characters; spaces are meaningful and the value is never logged or persisted."),
            )
        }
        val confirmMessage = if (mode == InstallCredentialMode.CUSTOM) {
            tr("确认立即写入自定义 3x-ui 账号和密码？现有会话会退出，2FA 可能被关闭。", "Apply the custom 3x-ui username and password now? Existing sessions will be logged out and 2FA may be disabled.")
        } else {
            tr("生成并应用新的随机 3x-ui 用户名和密码？现有会话会退出，2FA 可能被关闭。", "Generate and apply new random 3x-ui credentials? Existing sessions will be logged out and 2FA may be disabled.")
        }
        if (!confirmYes(confirmMessage, false)) return
        var inputPath: String? = null
        try {
            if (mode == InstallCredentialMode.CUSTOM) {
                inputPath = writeOneRunInput(
                    handle,
                    "PANEL_USERNAME_B64=${b64(customAccount)}\nPANEL_PASSWORD_B64=${b64(customPassword)}\n",
                    "credential-input",
                )
            }
            val env = buildString {
                append("PNA_PANEL_CREDENTIAL_MODE=")
                append(SshHandle.shellQuote(mode.wireValue))
                val path = inputPath
                if (path != null) {
                    append(" PNA_CREDENTIAL_INPUT=")
                    append(SshHandle.shellQuote(path))
                }
            }
            checked(handle, "source $REMOTE_ROOT/linux/lib-handoff.sh; handoff_begin_run; $env bash $REMOTE_ROOT/linux/03c-rotate-panel-credentials.sh")
        } finally {
            inputPath?.let { path -> withContext(NonCancellable) { removeOneRunInput(handle, path) } }
        }
        showHandoff(handle)
    }

    /** Menu [5]/[6] mutation policy: random, custom, or an explicit return. */
    private suspend fun chooseCredentialMutationMode(title: String, message: String): InstallCredentialMode? {
        val answer = prompts.ask(
            title,
            message,
            PromptKind.CHOICE,
            options = listOf(
                "RANDOM | ${tr("生成新的高强度随机值", "generate a new high-entropy value")}",
                "CUSTOM | ${tr("手动输入并二次确认", "enter and confirm manually")}",
                "CANCEL | ${tr("返回，不修改远端", "return without changing the VPS")}",
            ),
        )
        val token = answer.trim().substringBefore('|').substringBefore('｜').trim().lowercase(Locale.ROOT)
        return when {
            token == "random" || token == "r" || token == "1" -> InstallCredentialMode.RANDOM
            token == "custom" || token == "c" || token == "2" -> InstallCredentialMode.CUSTOM
            token == "cancel" || token == "q" || token == "0" -> null
            else -> error(tr("凭据策略选择无效", "Invalid credential policy selection"))
        }
    }

    private suspend fun optimizeCover(handle: SshHandle) {
        val env = ProtocolParsers.kv(checked(handle, "cat /etc/proxy-runbook/public.env 2>/dev/null; cat /etc/text-node-assistant/public.env 2>/dev/null", emit = false).stdout)
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
            safe.contains("Remote toolkit is incomplete", true) -> "远端工具包不完整，请运行菜单 [1] 并确认 APPLY 原位修复"
            safe.contains("remote command failed", true) -> safe.replace("remote command failed", "远端命令执行失败")
            safe.startsWith("操作") || safe.startsWith("SSH") || safe.startsWith("远端") -> safe
            else -> "操作失败：$safe"
        }
    }

    private fun tr(zh: String, en: String): String = if (language == Language.ZH) zh else en

    companion object {
        const val VERSION = "1.0.0"
        const val BUILD_ID = "20260901-v100-ss2022-r109"
        const val BUILD_REVISION = 109
        const val REMOTE_ROOT = "/opt/proxy-node-assistant-current"
        const val LEGACY_TEXT_REMOTE_ROOT = "/opt/text-node-assistant-current"
        const val LEGACY_REMOTE_ROOT = "/opt/proxy-runbook-current"
        const val INSTALL_ROOT = "/opt/proxy-node-assistant-v1.0.0"
        const val TOOLKIT_ASSET = "proxy-node-assistant-toolkit-v1.0.0.tgz"
        const val TOOLKIT_ARCHIVE = "proxy-node-assistant-toolkit-v1.0.0.tar.gz"
        const val CLOUDFLARE_DNS_DASHBOARD = "https://dash.cloudflare.com/"

        /**
         * Only action [1] may replace a partial same-version toolkit, and it
         * does so after the exact APPLY confirmation.  A newer revision (or a
         * divergent ID at the same revision) must remain protected from an
         * older Android client. A revision-zero probe is treated as an
         * interrupted upload (the metadata was never written), but a
         * current-revision probe with a blank or divergent ID is ambiguous and
         * is rejected fail-closed.
         */
        fun sameVersionIncompleteRepairAllowed(probe: ToolkitProbe): Boolean {
            if (!probe.installed || probe.complete || probe.version != VERSION || probe.buildRevision < 0) return false
            if (probe.buildRevision > BUILD_REVISION) return false
            if (probe.buildRevision == BUILD_REVISION && probe.buildId != BUILD_ID) return false
            return true
        }

        /**
         * Return true only for a clearly older or incomplete same-version
         * toolkit.  Those states are eligible for a package-only refresh after
         * APPLY; a different/newer build ID at the current revision remains
         * protected by the caller's downgrade guard.
         */
        fun sameVersionToolkitOnlyUpdateRequired(probe: ToolkitProbe): Boolean {
            if (!probe.installed || probe.version != VERSION) return false
            if (!probe.complete) return sameVersionIncompleteRepairAllowed(probe)
            return probe.buildRevision < BUILD_REVISION
        }

        val COVER_TEMPLATE_CATALOG = """
            1 atlas-journal   2 northstar-studio   3 cedar-stone
            4 field-lab       5 harbor-weather     6 local-library
            7 ember-cafe      8 trail-guide        9 signal-status
            10 mono-docs      11 analog-radio      12 city-calendar
            13 pixel-gallery  14 quiet-finance     15 signal-runner
        """.trimIndent()
    }
}
