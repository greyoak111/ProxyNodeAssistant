package com.proxynodeassistant.android.model

enum class Language { ZH, EN }

enum class AuthMode { TEMPORARY_PASSWORD, MANAGED_KEY }

data class NodeTarget(
    val host: String,
    val user: String = "root",
    val port: Int = 22,
    val label: String = "",
    val lastUsedEpochMs: Long = System.currentTimeMillis(),
) {
    val id: String get() = "$user@$host:$port"
}

data class HostKeyRecord(
    val targetId: String,
    val algorithm: String,
    val keyBase64: String,
    val fingerprint: String,
    val acceptedEpochMs: Long = System.currentTimeMillis(),
)

data class ManagedKeyRecord(
    val targetId: String,
    val privateKeyOpenSsh: String,
    val publicKeyOpenSsh: String,
    val status: KeyStatus = KeyStatus.BOUND,
    val createdEpochMs: Long = System.currentTimeMillis(),
)

/**
 * Stable identity reported by the node-identity protocol.  This is a safety
 * binding for an endpoint change (for example a provider-assigned public IP
 * change); it is deliberately unrelated to per-client admission or storage features.
 */
data class StableNodeIdentity(
    val targetId: String,
    val serverId: String,
    val nodeId: String,
    val machineIdSha256: String,
    val hostKeySha256: String,
    val firstKnownPublicIp: String,
    val currentPublicIp: String,
)

enum class KeyStatus { BOUND, BACKUP }

enum class PromptKind { TEXT, SECRET, YES_NO, HOST_KEY, EXACT_CONFIRMATION, CHOICE }

data class WorkflowPrompt(
    val id: Long,
    val title: String,
    val message: String,
    val kind: PromptKind,
    val placeholder: String = "",
    val defaultValue: String = "",
    val options: List<String> = emptyList(),
    val danger: Boolean = false,
)

enum class RunStatus { IDLE, CONNECTING, RUNNING, WAITING_INPUT, SUCCEEDED, FAILED, CANCELLED }

data class WorkflowUiState(
    val status: RunStatus = RunStatus.IDLE,
    val action: ActionSpec? = null,
    val target: NodeTarget? = null,
    val log: List<String> = emptyList(),
    val prompt: WorkflowPrompt? = null,
    val error: String? = null,
    val panelUrl: String? = null,
    val secretHandoff: String? = null,
    val downloadedFile: String? = null,
    val startedAtEpochMs: Long? = null,
)

data class RemoteResult(val exitCode: Int, val stdout: String, val stderr: String) {
    val ok: Boolean get() = exitCode == 0
}

data class PanelMetadata(val port: Int, val path: String, val source: String)

data class ToolkitProbe(
    val installed: Boolean,
    val complete: Boolean,
    val version: String = "",
    val buildId: String = "",
    val buildRevision: Int = 0,
    /** Optional identity fields emitted by newer probes; old probes omit them. */
    val brand: String = "",
    val root: String = "",
)

data class KiwiUsage(
    val veid: String,
    val hostname: String,
    val location: String,
    val plan: String,
    val usedBytes: Long,
    val allowanceBytes: Long,
    val multiplier: Double,
    val resetEpochSeconds: Long,
    val suspended: Boolean,
    val policyViolation: Boolean,
) {
    val fraction: Double get() = (usedBytes.toDouble() / allowanceBytes.toDouble()).coerceIn(0.0, 1.0)
    val percent: Double get() = fraction * 100.0
}

data class CachedKiwiUsage(
    val usage: KiwiUsage,
    val checkedEpochMs: Long,
)

data class ProviderProfileSummary(
    val veid: String,
    val cached: CachedKiwiUsage? = null,
    val hasSavedKey: Boolean = false,
)

enum class ActionGroup { INSTALL, ACCESS, MAINTENANCE, SECURITY, BACKUP, LOCAL }

data class ActionSpec(
    val code: String,
    val titleZh: String,
    val titleEn: String,
    val descriptionZh: String,
    val descriptionEn: String,
    val group: ActionGroup,
    val remote: Boolean = true,
    val destructive: Boolean = false,
)

object ActionCatalog {
    val all = listOf(
        ActionSpec("1", "安装 / 升级 / 自适应优化", "Install / upgrade / adaptive optimize", "唯一安装入口；必须明确选路线、模板、性能和 WARP，预览后输入 APPLY 才上传或施工。", "The only install entry. Explicitly select route, cover, performance, and WARP; upload or changes begin only after an APPLY review.", ActionGroup.INSTALL),
        ActionSpec("2", "打开 3x-ui 面板", "Open 3x-ui panel", "通过 Android 本机 127.0.0.1 SSH 隧道访问。", "Access through an Android localhost SSH tunnel.", ActionGroup.ACCESS),
        ActionSpec("3", "自动体检与排障", "Diagnose", "结构化检查 SSH、x-ui、Nginx、WARP、订阅和端口，并从本机分层探测 Reality、橙云/XHTTP、SS2022 三条入口。", "Structured SSH, x-ui, Nginx, WARP, subscription, and port checks, plus layered handset probes for Reality, CDN/XHTTP, and SS2022.", ActionGroup.MAINTENANCE),
        ActionSpec("4", "安全自动修复", "Safe repair", "先备份，只修复可确定性问题。", "Back up first and repair deterministic issues only.", ActionGroup.MAINTENANCE),
        ActionSpec("5", "设置 / 轮换 VPS 登录密码", "Set / rotate VPS password", "可选择随机值或自定义值；通过校验后输出真实交接单。", "Choose a random or custom value; return a validated real handoff.", ActionGroup.SECURITY),
        ActionSpec("6", "设置 / 轮换 3x-ui 账号密码", "Set / rotate panel credentials", "可选择随机值或自定义账号密码；通过校验后输出真实交接单。", "Choose random or custom panel credentials; return a validated handoff.", ActionGroup.SECURITY),
        ActionSpec("7", "显示当前凭据交接单", "Show credential handoff", "读取并验证当前真实凭据。", "Read and validate current real credentials.", ActionGroup.ACCESS),
        ActionSpec("8", "优化伪装网站与 Nginx", "Optimize cover site and Nginx", "随机或指定 15 套本地模板，不依赖第三方 CDN。", "Random or exact selection from 15 local templates without third-party CDN.", ActionGroup.MAINTENANCE),
        ActionSpec("9", "完整灾难恢复备份", "Full disaster-recovery backup", "仅含程序与远端节点配置，体积较大。", "Contains the program and remote-node configuration; potentially large.", ActionGroup.BACKUP),
        ActionSpec("10", "生成紧急诊断报告", "Emergency diagnostic report", "生成后通过 SSH 下载到手机指定位置。", "Generate and download through SSH to a user-selected document.", ActionGroup.BACKUP),
        ActionSpec("11", "绑定 / 轮换 SSH 登录密钥", "Bind / rotate SSH key", "先验证新钥，再撤旧钥。", "Verify the new key before revoking the old key.", ActionGroup.SECURITY),
        ActionSpec("12", "清空应用内秘密剪贴板", "Clear secret clipboard", "清空本应用写入的剪贴板内容。", "Clear clipboard content written by this app.", ActionGroup.LOCAL, remote = false),
        ActionSpec("13", "卸载远端内嵌包", "Uninstall remote toolkit", "保留节点、配置、凭据和备份。", "Keep node services, configuration, credentials, and backups.", ActionGroup.MAINTENANCE, destructive = true),
        ActionSpec("14", "Android 本地代理控制", "Android local proxy control", "查看 10808；提供应用内代理目标与隧道状态，不伪造系统环境变量。", "Inspect 10808 and manage app-local proxy/tunnel state; no fake system env vars.", ActionGroup.LOCAL, remote = false),
        ActionSpec("15", "整理远端备份", "Prune remote backups", "只保留一份新验证的当前配置备份。", "Retain exactly one newly verified current-config backup.", ActionGroup.BACKUP, destructive = true),
        ActionSpec("16", "自适应性能档", "Adaptive performance profile", "检测资源并应用可回滚档位。", "Detect capacity and apply a reversible profile.", ActionGroup.MAINTENANCE),
        ActionSpec("17", "SSH / vnStat 流量估算", "SSH / vnStat traffic estimate", "查看系统网卡累计流量，不等同厂商计费。", "View interface counters; not provider billing.", ActionGroup.MAINTENANCE),
        ActionSpec("18", "拆除所有施工并恢复基线", "Dismantle all managed changes", "先生成救援包，再拆除已知施工。", "Create a rescue archive before removing managed changes.", ActionGroup.MAINTENANCE, destructive = true),
        ActionSpec("19", "识别本机 IP 并添加 SS2022 白名单", "Detect local IP and add to SS2022 allowlist", "先在本机直连识别公网 IPv4，再与 VPS 看到的 SSH 来源核对；明确确认后才加入 SS2022 精确白名单。完整列表与自由增删请使用并列的 OP:24。", "Detect the public IPv4 locally, compare it with the source seen by the VPS, and add the exact source to the SS2022 allowlist only after explicit confirmation. Use the parallel OP:24 for the full list and free add/remove.", ActionGroup.SECURITY),
        ActionSpec("24", "管理 SS2022 白名单（与 OP:19 并列）", "Manage SS2022 allowlist (parallel to OP:19)", "查看当前精确 IPv4 白名单，然后可自由添加或删除；不接受 CIDR 或网段。", "View the exact-IPv4 allowlist, then freely add/remove entries; CIDR ranges are never accepted.", ActionGroup.SECURITY),
        // v0.9.5 maintenance actions retained under their original codes;
        // retired experimental enrollment/storage entries are intentionally absent.
        ActionSpec("20", "访问与封禁日志", "Access and ban events", "按需读取 SSH、Fail2ban、防火墙和入口的聚合元数据；可明确确认后应用受管安全基线。", "Read bounded SSH, Fail2ban, firewall, and ingress metadata; apply the managed security baseline only after explicit confirmation.", ActionGroup.SECURITY),
        ActionSpec("22", "CDN/XHTTP 线路控制中心", "CDN/XHTTP route control center", "保留 v0.9.5 的灰云/橙云/XHTTP 分阶段施工、边缘验收、真实客户端提交、回滚和组件清理；每个公网变更均需明确确认，不包含网盘或强制本机门槛。", "Retain the v0.9.5 gray/orange CDN-XHTTP staging, edge validation, real-client commit, rollback, and component cleanup flow; every public mutation requires explicit confirmation, with no drive or forced local-device gate.", ActionGroup.MAINTENANCE),
        ActionSpec("23", "更换公网 IP 后安全重绑定", "Safely rebind a changed public IP", "复用原 SSH key，并在 Host Key、machine-id、NODE_ID/SERVER_ID 全部一致后才提交新地址。", "Reuse the original SSH key and commit a new endpoint only after host key, machine-id, and NODE_ID/SERVER_ID all match.", ActionGroup.SECURITY),
        ActionSpec("T", "服务商流量中心", "Provider traffic center", "KiwiVM 临时 API Key 或经确认加密保存；其他厂商按能力接入。", "Temporary KiwiVM API key or confirmed encrypted storage; other providers by capability.", ActionGroup.LOCAL, remote = false),
        ActionSpec("K", "管理节点 SSH key", "Manage node SSH keys", "查看、备份态、恢复、轮换和解绑。", "Inspect, archive, restore, rotate, and unbind keys.", ActionGroup.SECURITY, remote = false),
        ActionSpec("H", "管理 VPS 历史", "Manage VPS history", "快速选择、编辑或一键删除历史。", "Quickly select, edit, or delete history.", ActionGroup.LOCAL, remote = false),
    )

    fun byCode(code: String): ActionSpec = requireNotNull(all.firstOrNull { it.code.equals(code, true) })
}
