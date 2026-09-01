package com.proxynodeassistant.android.ui

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.PersistableBundle
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.proxynodeassistant.android.ProxyNodeApplication
import com.proxynodeassistant.android.model.ActionSpec
import com.proxynodeassistant.android.model.AuthMode
import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.KiwiUsage
import com.proxynodeassistant.android.model.Language
import com.proxynodeassistant.android.model.ManagedKeyRecord
import com.proxynodeassistant.android.model.NodeTarget
import com.proxynodeassistant.android.model.ProviderProfileSummary
import com.proxynodeassistant.android.model.WorkflowPrompt
import com.proxynodeassistant.android.model.WorkflowUiState
import com.proxynodeassistant.android.data.PortableKeyBackup
import com.proxynodeassistant.android.service.TunnelRegistry
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.net.InetSocketAddress
import java.net.Socket

enum class AppPage { DASHBOARD, WORKFLOW, KEYS, HISTORY, LOCAL, PROVIDER, ABOUT }

data class AppUiState(
    val page: AppPage = AppPage.DASHBOARD,
    val language: Language = Language.ZH,
    val selectedAction: ActionSpec? = null,
    val showConnection: Boolean = false,
    val targets: List<NodeTarget> = emptyList(),
    val keys: List<ManagedKeyRecord> = emptyList(),
    val localProxyEnabled: Boolean = false,
    val localProxyReachable: Boolean? = null,
    val providerLoading: Boolean = false,
    val providerUsage: KiwiUsage? = null,
    val providerError: String? = null,
    val providerWarningPercent: Int = 80,
    val providerProfiles: List<ProviderProfileSummary> = emptyList(),
    val toast: String? = null,
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val container = (application as ProxyNodeApplication).container
    private val preferences = application.getSharedPreferences("ui", Context.MODE_PRIVATE)
    private val _ui = MutableStateFlow(
        AppUiState(
            language = if (preferences.getString("language", "zh") == "en") Language.EN else Language.ZH,
            targets = container.targets.list(),
            keys = container.managedKeys.list(),
            localProxyEnabled = preferences.getBoolean("local_proxy_10808", false),
            providerWarningPercent = preferences.getInt("provider_warning_percent", 80).coerceIn(1, 100),
            providerProfiles = buildProviderProfiles(),
        ),
    )
    val ui: StateFlow<AppUiState> = _ui.asStateFlow()
    val workflow: StateFlow<WorkflowUiState> = container.workflows.state
    val prompt: StateFlow<WorkflowPrompt?> = container.prompts.prompt
    val tunnelUrl: StateFlow<String?> = TunnelRegistry.url

    fun selectAction(action: ActionSpec) {
        when (action.code.uppercase()) {
            "12" -> clearClipboard()
            "14" -> navigate(AppPage.LOCAL)
            "T" -> navigate(AppPage.PROVIDER)
            "K" -> navigate(AppPage.KEYS)
            "H" -> navigate(AppPage.HISTORY)
            else -> _ui.value = _ui.value.copy(selectedAction = action, showConnection = true)
        }
    }

    fun dismissConnection() { _ui.value = _ui.value.copy(showConnection = false) }

    fun launch(target: NodeTarget, mode: AuthMode, password: String?) {
        val action = requireNotNull(_ui.value.selectedAction)
        _ui.value = _ui.value.copy(showConnection = false, page = AppPage.WORKFLOW, targets = (listOf(target) + _ui.value.targets.filterNot { it.id == target.id }).take(50))
        container.workflows.run(action, target, mode, password, _ui.value.language)
    }

    fun submitPrompt(value: String) { container.workflows.submitPrompt(value) }
    fun cancelWorkflow() { container.workflows.cancel() }
    fun clearWorkflow() { container.workflows.clear(); navigate(AppPage.DASHBOARD) }

    fun navigate(page: AppPage) {
        _ui.value = _ui.value.copy(page = page, showConnection = false, targets = container.targets.list(), keys = container.managedKeys.list(), providerProfiles = buildProviderProfiles())
    }

    fun toggleLanguage() {
        val next = if (_ui.value.language == Language.ZH) Language.EN else Language.ZH
        preferences.edit().putString("language", if (next == Language.EN) "en" else "zh").apply()
        _ui.value = _ui.value.copy(language = next)
    }

    fun deleteTarget(id: String) { container.targets.delete(id); _ui.value = _ui.value.copy(targets = container.targets.list()) }
    fun clearTargets() { container.targets.clear(); _ui.value = _ui.value.copy(targets = emptyList()) }

    fun archiveKey(targetId: String) { container.managedKeys.archive(targetId); refreshKeys(tr("密钥已转入可恢复备份态", "Key moved to recoverable backup state")) }
    fun restoreKey(targetId: String, createdEpochMs: Long) {
        val restored = container.managedKeys.restore(targetId, createdEpochMs)
        refreshKeys(if (restored) tr("密钥已恢复到绑定态", "Key restored to bound state") else tr("绑定位置已占用，请先把当前密钥转入备份态", "Bound slot is occupied; archive it first"))
    }
    fun archiveAllKeys() { val count = container.managedKeys.archiveAll(); refreshKeys(tr("已将 $count 把密钥转入备份态", "$count key(s) moved to backup state")) }
    fun deleteBackup(targetId: String, createdEpochMs: Long) { container.managedKeys.delete(targetId, KeyStatus.BACKUP, createdEpochMs); refreshKeys(tr("所选密钥备份已删除", "Selected backup deleted")) }

    fun exportKeyBackup(passphrase: String): ByteArray = PortableKeyBackup.export(container.managedKeys.list(), passphrase.toCharArray())

    fun importKeyBackup(payload: ByteArray, passphrase: String): Int {
        val records = PortableKeyBackup.import(payload, passphrase.toCharArray())
        records.forEach { record ->
            val safeRecord = if (record.status == KeyStatus.BOUND && container.managedKeys.get(record.targetId, KeyStatus.BOUND) != null) record.copy(status = KeyStatus.BACKUP) else record
            container.managedKeys.put(safeRecord)
        }
        refreshKeys(tr("已导入 ${records.size} 条加密密钥记录", "${records.size} encrypted key record(s) imported"))
        return records.size
    }

    fun showMessage(message: String) { _ui.value = _ui.value.copy(toast = message.take(300)) }

    fun copySecret(text: String) {
        val clipboard = getApplication<Application>().getSystemService(ClipboardManager::class.java)
        val clip = ClipData.newPlainText("ProxyNodeAssistant secret", text)
        clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
        clipboard.setPrimaryClip(clip)
        _ui.value = _ui.value.copy(toast = tr("已复制；保存到密码管理器后请立即清空剪贴板", "Copied. Clear it after saving."))
    }

    fun clearClipboard() {
        val clipboard = getApplication<Application>().getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        _ui.value = _ui.value.copy(toast = tr("剪贴板已清空", "Clipboard cleared"))
    }

    fun consumeToast() { _ui.value = _ui.value.copy(toast = null) }
    fun closeTunnel() { TunnelRegistry.close(getApplication()) }

    fun setLocalProxyEnabled(enabled: Boolean) {
        preferences.edit().putBoolean("local_proxy_10808", enabled).apply()
        _ui.value = _ui.value.copy(localProxyEnabled = enabled)
        checkLocalProxy()
    }

    fun checkLocalProxy() {
        _ui.value = _ui.value.copy(localProxyReachable = null)
        viewModelScope.launch(Dispatchers.IO) {
            val reachable = runCatching {
                Socket().use { socket -> socket.connect(InetSocketAddress("127.0.0.1", 10808), 900) }
                true
            }.getOrDefault(false)
            _ui.value = _ui.value.copy(localProxyReachable = reachable)
        }
    }

    fun setProviderWarningPercent(value: Int) {
        val normalized = value.coerceIn(1, 100)
        preferences.edit().putInt("provider_warning_percent", normalized).apply()
        _ui.value = _ui.value.copy(providerWarningPercent = normalized)
    }

    fun fetchKiwiUsage(veid: String, suppliedApiKey: String, rememberKey: Boolean) {
        val normalizedVeid = veid.trim()
        if (!normalizedVeid.matches(Regex("^[0-9]{3,12}$"))) {
            _ui.value = _ui.value.copy(providerError = tr("VEID 必须是 3—12 位数字", "VEID must contain 3-12 digits"))
            return
        }
        val key = suppliedApiKey.trim().ifBlank { container.providerCredentials.get("kiwivm", normalizedVeid).orEmpty() }
        if (key.isBlank()) {
            _ui.value = _ui.value.copy(providerError = tr("请输入 API Key，或选择一条已经加密保存密钥的节点记录", "Enter an API key or use a VEID with an encrypted saved key"))
            return
        }
        _ui.value = _ui.value.copy(providerLoading = true, providerError = null)
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { container.providerTraffic.kiwiServiceInfo(normalizedVeid, key, _ui.value.localProxyEnabled) }
                .onSuccess { usage ->
                    if (rememberKey && suppliedApiKey.isNotBlank()) container.providerCredentials.put("kiwivm", normalizedVeid, suppliedApiKey.trim())
                    container.providerUsage.put(usage)
                    _ui.value = _ui.value.copy(
                        providerLoading = false,
                        providerUsage = usage,
                        providerError = null,
                        providerProfiles = buildProviderProfiles(),
                        toast = tr("流量已刷新并保存本地快照", "Traffic refreshed and cached locally"),
                    )
                }
                .onFailure { error ->
                    val safe = (error.message ?: error.javaClass.simpleName)
                        .replace(key, tr("<已隐藏>", "<redacted>"))
                        .replace(Regex("(?i)(api[_ -]?key|password|token)=\\S+"), "$1=<redacted>")
                    _ui.value = _ui.value.copy(providerLoading = false, providerError = localizeProviderError(safe).take(400))
                }
        }
    }

    fun refreshSavedKiwiUsage(veid: String) = fetchKiwiUsage(veid, "", false)

    fun showCachedKiwiUsage(veid: String) {
        val cached = container.providerUsage.get(veid)
        _ui.value = if (cached == null) {
            _ui.value.copy(providerError = tr("这条记录还没有本地流量快照，请先联网刷新", "This profile has no cached traffic snapshot; refresh it online first"))
        } else {
            _ui.value.copy(providerUsage = cached.usage, providerError = null, toast = tr("正在显示本地快照，不读取 API Key", "Showing the local snapshot without reading the API key"))
        }
    }

    fun forgetKiwiKey(veid: String) {
        val normalized = veid.trim()
        if (normalized.isNotBlank()) container.providerCredentials.delete("kiwivm", normalized)
        _ui.value = _ui.value.copy(toast = tr("已删除加密保存的 KiwiVM API Key；本地流量快照仍保留", "Saved KiwiVM key removed; the local traffic snapshot remains"), providerProfiles = buildProviderProfiles())
    }

    fun deleteKiwiProfile(veid: String) {
        val normalized = veid.trim()
        container.providerCredentials.delete("kiwivm", normalized)
        container.providerUsage.delete(normalized)
        _ui.value = _ui.value.copy(
            providerUsage = _ui.value.providerUsage?.takeUnless { it.veid == normalized },
            providerProfiles = buildProviderProfiles(),
            providerError = null,
            toast = tr("该节点的本地快照和加密 API Key 已删除", "The local snapshot and encrypted API key were deleted"),
        )
    }

    private fun buildProviderProfiles(): List<ProviderProfileSummary> {
        val cached = container.providerUsage.list().associateBy { it.usage.veid }
        val ids = (cached.keys + container.providerCredentials.profileIds("kiwivm")).distinct().sorted()
        return ids.map { ProviderProfileSummary(it, cached[it], container.providerCredentials.has("kiwivm", it)) }
    }

    private fun localizeProviderError(message: String): String {
        if (_ui.value.language != Language.ZH) return message
        return when {
            message.contains("VEID must contain", true) -> "VEID 必须是 3—12 位数字"
            message.contains("Invalid KiwiVM API key", true) -> "KiwiVM API Key 格式无效"
            message.contains("returned HTTP", true) -> message.replace("KiwiVM returned HTTP", "KiwiVM 返回了 HTTP 状态码")
            message.contains("empty or oversized", true) -> "KiwiVM 返回内容为空或超过安全大小限制"
            message.contains("rejected the request", true) -> "KiwiVM API 拒绝了本次请求，请检查 VEID 与 API Key"
            message.contains("missing valid transfer counters", true) -> "KiwiVM 响应缺少有效的流量计数字段"
            message.contains("Connection refused", true) -> "连接被拒绝；若启用了 10808，请先确认本机代理端口正在监听"
            else -> "查询失败：$message"
        }
    }

    private fun tr(zh: String, en: String): String = if (_ui.value.language == Language.ZH) zh else en

    private fun refreshKeys(message: String) { _ui.value = _ui.value.copy(keys = container.managedKeys.list(), toast = message) }
}
