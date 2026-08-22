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
        ActionSpec("1", "安装 / 升级 / 自适应优化", "Install / upgrade / adaptive optimize", "唯一安装入口；识别远端版本后安装、升级或只收敛配置。", "The only install entry; version-aware install, upgrade, or convergence.", ActionGroup.INSTALL),
        ActionSpec("2", "打开 3x-ui 面板", "Open 3x-ui panel", "通过 Android 本机 127.0.0.1 SSH 隧道访问。", "Access through an Android localhost SSH tunnel.", ActionGroup.ACCESS),
        ActionSpec("3", "自动体检与排障", "Diagnose", "结构化检查 SSH、x-ui、Nginx、WARP、订阅和端口。", "Structured SSH, x-ui, Nginx, WARP, subscription, and port checks.", ActionGroup.MAINTENANCE),
        ActionSpec("4", "安全自动修复", "Safe repair", "先备份，只修复可确定性问题。", "Back up first and repair deterministic issues only.", ActionGroup.MAINTENANCE),
        ActionSpec("5", "随机化 VPS 登录密码", "Rotate VPS password", "生成并显示真实高强度密码。", "Generate and display a real high-entropy password.", ActionGroup.SECURITY),
        ActionSpec("6", "随机化 3x-ui 账号密码", "Rotate panel credentials", "更新面板身份并输出经过校验的交接单。", "Rotate panel identity and return a validated handoff.", ActionGroup.SECURITY),
        ActionSpec("7", "显示当前凭据交接单", "Show credential handoff", "读取并验证当前真实凭据。", "Read and validate current real credentials.", ActionGroup.ACCESS),
        ActionSpec("8", "优化伪装网站与 Nginx", "Optimize cover site and Nginx", "随机或指定 15 套本地模板，不依赖第三方 CDN。", "Random or exact selection from 15 local templates without third-party CDN.", ActionGroup.MAINTENANCE),
        ActionSpec("9", "完整灾难恢复备份", "Full disaster-recovery backup", "含程序和身份，体积较大。", "Includes programs and identities; potentially large.", ActionGroup.BACKUP),
        ActionSpec("10", "生成紧急诊断报告", "Emergency diagnostic report", "生成后通过 SSH 下载到手机指定位置。", "Generate and download through SSH to a user-selected document.", ActionGroup.BACKUP),
        ActionSpec("11", "绑定 / 轮换 SSH 登录密钥", "Bind / rotate SSH key", "先验证新钥，再撤旧钥。", "Verify the new key before revoking the old key.", ActionGroup.SECURITY),
        ActionSpec("12", "清空应用内秘密剪贴板", "Clear secret clipboard", "清空本应用写入的剪贴板内容。", "Clear clipboard content written by this app.", ActionGroup.LOCAL, remote = false),
        ActionSpec("13", "卸载远端内嵌包", "Uninstall remote toolkit", "保留节点、配置、凭据和备份。", "Keep node services, configuration, credentials, and backups.", ActionGroup.MAINTENANCE, destructive = true),
        ActionSpec("14", "Android 本地代理控制", "Android local proxy control", "查看 10808；提供应用内代理目标与隧道状态，不伪造系统环境变量。", "Inspect 10808 and manage app-local proxy/tunnel state; no fake system env vars.", ActionGroup.LOCAL, remote = false),
        ActionSpec("15", "整理远端备份", "Prune remote backups", "只保留一份新验证的当前配置备份。", "Retain exactly one newly verified current-config backup.", ActionGroup.BACKUP, destructive = true),
        ActionSpec("16", "自适应性能档", "Adaptive performance profile", "检测资源并应用可回滚档位。", "Detect capacity and apply a reversible profile.", ActionGroup.MAINTENANCE),
        ActionSpec("17", "SSH / vnStat 流量估算", "SSH / vnStat traffic estimate", "查看系统网卡累计流量，不等同厂商计费。", "View interface counters; not provider billing.", ActionGroup.MAINTENANCE),
        ActionSpec("18", "拆除所有施工并恢复基线", "Dismantle all managed changes", "先生成救援包，再拆除已知施工。", "Create a rescue archive before removing managed changes.", ActionGroup.MAINTENANCE, destructive = true),
        ActionSpec("T", "服务商流量中心", "Provider traffic center", "KiwiVM 临时 API Key 或经确认加密保存；其他厂商按能力接入。", "Temporary KiwiVM API key or confirmed encrypted storage; other providers by capability.", ActionGroup.LOCAL, remote = false),
        ActionSpec("K", "管理节点 SSH key", "Manage node SSH keys", "查看、备份态、恢复、轮换和解绑。", "Inspect, archive, restore, rotate, and unbind keys.", ActionGroup.SECURITY, remote = false),
        ActionSpec("H", "管理 VPS 历史", "Manage VPS history", "快速选择、编辑或一键删除历史。", "Quickly select, edit, or delete history.", ActionGroup.LOCAL, remote = false),
    )

    fun byCode(code: String): ActionSpec = requireNotNull(all.firstOrNull { it.code.equals(code, true) })
}
