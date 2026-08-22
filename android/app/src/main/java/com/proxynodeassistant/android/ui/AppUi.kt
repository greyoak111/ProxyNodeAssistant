package com.proxynodeassistant.android.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AdminPanelSettings
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.OpenInBrowser
import androidx.compose.material.icons.outlined.Security
import androidx.compose.material.icons.outlined.SettingsEthernet
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLocale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.core.content.FileProvider
import com.proxynodeassistant.android.core.Validation
import com.proxynodeassistant.android.model.ActionCatalog
import com.proxynodeassistant.android.model.ActionGroup
import com.proxynodeassistant.android.model.ActionSpec
import com.proxynodeassistant.android.model.AuthMode
import com.proxynodeassistant.android.model.KeyStatus
import com.proxynodeassistant.android.model.KiwiUsage
import com.proxynodeassistant.android.model.Language
import com.proxynodeassistant.android.model.NodeTarget
import com.proxynodeassistant.android.model.PromptKind
import com.proxynodeassistant.android.model.RunStatus
import com.proxynodeassistant.android.model.WorkflowPrompt
import com.proxynodeassistant.android.model.WorkflowUiState
import java.util.Locale
import java.util.Date
import java.text.SimpleDateFormat
import java.io.File

@Composable
fun PnaApp(viewModel: AppViewModel) {
    val ui by viewModel.ui.collectAsStateWithLifecycle()
    val workflow by viewModel.workflow.collectAsStateWithLifecycle()
    val prompt by viewModel.prompt.collectAsStateWithLifecycle()
    val tunnelUrl by viewModel.tunnelUrl.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(ui.toast) {
        ui.toast?.let { snackbar.showSnackbar(it); viewModel.consumeToast() }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = Ink,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = { PnaTopBar(ui.page, ui.language, workflow, viewModel) },
        bottomBar = { PnaBottomBar(ui.page, viewModel) },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).background(Ink)) {
            when (ui.page) {
                AppPage.DASHBOARD -> DashboardScreen(ui.language, viewModel::selectAction)
                AppPage.WORKFLOW -> WorkflowScreen(workflow, prompt, tunnelUrl, viewModel)
                AppPage.KEYS -> KeysScreen(ui.language, ui.keys, viewModel)
                AppPage.HISTORY -> HistoryScreen(ui.language, ui.targets, viewModel)
                AppPage.LOCAL -> LocalScreen(ui.language, tunnelUrl, ui.localProxyEnabled, ui.localProxyReachable, viewModel)
                AppPage.PROVIDER -> ProviderScreen(ui, viewModel)
                AppPage.ABOUT -> AboutScreen(ui.language)
            }
        }
    }
    val selectedAction = ui.selectedAction
    if (ui.showConnection && selectedAction != null) {
        ConnectionDialog(selectedAction, ui.targets, ui.language, viewModel::dismissConnection, viewModel::launch)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PnaTopBar(page: AppPage, language: Language, workflow: WorkflowUiState, viewModel: AppViewModel) {
    TopAppBar(
        modifier = Modifier.statusBarsPadding().border(0.5.dp, GridLine),
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Panel),
        title = {
            Column {
                Text("PNA // NODE OPS", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                Text("ANDROID 0.9.0 / LOCAL CONTROL / FAIL-CLOSED", color = TextMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
            }
        },
        navigationIcon = {
            if (page != AppPage.DASHBOARD) IconButton(onClick = { if (page == AppPage.WORKFLOW && workflow.status in setOf(RunStatus.RUNNING, RunStatus.CONNECTING, RunStatus.WAITING_INPUT)) viewModel.cancelWorkflow() else viewModel.navigate(AppPage.DASHBOARD) }) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
            }
        },
        actions = {
            TextButton(onClick = viewModel::toggleLanguage) {
                Icon(Icons.Outlined.Language, null, Modifier.size(17.dp)); Spacer(Modifier.width(6.dp)); Text(if (language == Language.ZH) "EN" else "中")
            }
        },
    )
}

@Composable
private fun PnaBottomBar(page: AppPage, viewModel: AppViewModel) {
    val items = listOf(
        Triple(AppPage.DASHBOARD, Icons.Outlined.Home, "OPS"),
        Triple(AppPage.HISTORY, Icons.Outlined.History, "NODES"),
        Triple(AppPage.KEYS, Icons.Outlined.Key, "KEYS"),
        Triple(AppPage.LOCAL, Icons.Outlined.SettingsEthernet, "LOCAL"),
        Triple(AppPage.ABOUT, Icons.Outlined.Security, "INFO"),
    )
    NavigationBar(containerColor = Panel, modifier = Modifier.navigationBarsPadding().border(0.5.dp, GridLine)) {
        items.forEach { (target, icon, label) ->
            NavigationBarItem(selected = page == target, onClick = { viewModel.navigate(target) }, icon = { Icon(icon, null) }, label = { Text(label, fontFamily = FontFamily.Monospace, fontSize = 10.sp) })
        }
    }
}

@Composable
private fun DashboardScreen(language: Language, onAction: (ActionSpec) -> Unit) {
    var group by rememberSaveable { mutableStateOf<ActionGroup?>(null) }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxWidth().background(Panel).padding(16.dp)) {
            Text(if (language == Language.ZH) "节点基础设施运维控制面" else "NODE INFRASTRUCTURE CONTROL PLANE", fontWeight = FontWeight.Black, fontSize = 21.sp)
            Text(if (language == Language.ZH) "每项远端操作重新选择节点和认证模式；Android 客户端不内置任何真实目标或秘密。" else "Every remote action re-selects its target and authentication mode. No real target or secret is embedded.", color = TextMuted, fontSize = 12.sp)
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
                FilterChip(selected = group == null, onClick = { group = null }, label = { Text(if (language == Language.ZH) "全部" else "ALL") })
                ActionGroup.entries.forEach { item -> FilterChip(selected = group == item, onClick = { group = item }, label = { Text(item.name) }) }
            }
        }
        LazyVerticalGrid(
            columns = GridCells.Adaptive(280.dp),
            modifier = Modifier.fillMaxSize().padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(ActionCatalog.all.filter { group == null || it.group == group }, key = { it.code }) { action -> ActionCard(action, language, onAction) }
        }
    }
}

@Composable
private fun ActionCard(action: ActionSpec, language: Language, onAction: (ActionSpec) -> Unit) {
    val accent = when (action.group) {
        ActionGroup.SECURITY -> Amber
        ActionGroup.BACKUP -> Color(0xFFB997FF)
        ActionGroup.MAINTENANCE -> Mint
        ActionGroup.LOCAL -> Color(0xFF59BFFF)
        else -> Cyan
    }
    OutlinedCard(
        modifier = Modifier.fillMaxWidth().height(178.dp).clickable { onAction(action) },
        shape = RoundedCornerShape(3.dp),
        border = BorderStroke(1.dp, GridLine),
        colors = CardDefaults.outlinedCardColors(containerColor = Panel),
    ) {
        Column(Modifier.fillMaxSize().padding(15.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("OP:${action.code.padStart(2, '0')}", color = accent, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
                Text(if (action.remote) "REMOTE" else "LOCAL", color = TextMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp, modifier = Modifier.border(1.dp, GridLine).padding(horizontal = 7.dp, vertical = 3.dp))
            }
            Column {
                Text(if (language == Language.ZH) action.titleZh else action.titleEn, fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(6.dp))
                Text(if (language == Language.ZH) action.descriptionZh else action.descriptionEn, color = TextMuted, fontSize = 12.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(7.dp).background(if (action.destructive) Amber else Mint)); Spacer(Modifier.width(7.dp))
                Text(if (action.destructive) "CONFIRMATION REQUIRED" else "READY", color = if (action.destructive) Amber else TextMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
            }
        }
    }
}

@Composable
private fun ConnectionDialog(
    action: ActionSpec,
    targets: List<NodeTarget>,
    language: Language,
    onDismiss: () -> Unit,
    onLaunch: (NodeTarget, AuthMode, String?) -> Unit,
) {
    var host by rememberSaveable { mutableStateOf(targets.firstOrNull()?.host.orEmpty()) }
    var user by rememberSaveable { mutableStateOf(targets.firstOrNull()?.user ?: "root") }
    var port by rememberSaveable { mutableStateOf((targets.firstOrNull()?.port ?: 22).toString()) }
    var mode by rememberSaveable { mutableStateOf(AuthMode.MANAGED_KEY) }
    var password by remember { mutableStateOf("") }
    val valid = Validation.validHost(host) && Validation.validUser(user) && port.toIntOrNull()?.let(Validation::validPort) == true
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(), color = Ink) {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth().background(Panel).border(0.5.dp, GridLine).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, null) }
                    Column {
                        Text("OP:${action.code} // ${if (language == Language.ZH) action.titleZh else action.titleEn}", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
                        Text(if (language == Language.ZH) "选择目标与本次 SSH 身份" else "SELECT TARGET AND AUTH FOR THIS RUN", color = TextMuted, fontSize = 11.sp)
                    }
                }
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    SectionLabel("AUTHENTICATION MODE")
                    Row(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                        FilterChip(selected = mode == AuthMode.MANAGED_KEY, onClick = { mode = AuthMode.MANAGED_KEY }, label = { Text(if (language == Language.ZH) "节点长期 KEY" else "MANAGED KEY") }, leadingIcon = { Icon(Icons.Outlined.Key, null, Modifier.size(17.dp)) })
                        FilterChip(selected = mode == AuthMode.TEMPORARY_PASSWORD, onClick = { mode = AuthMode.TEMPORARY_PASSWORD }, label = { Text(if (language == Language.ZH) "临时密码" else "ONE-TIME PASSWORD") }, leadingIcon = { Icon(Icons.Outlined.Lock, null, Modifier.size(17.dp)) })
                    }
                    Text(if (language == Language.ZH) "长期 key 按 user@host:port 独立查找；若不存在，会先询问一次密码，再明确询问是否绑定。" else "Managed keys are isolated by user@host:port. If absent, one password is requested before an explicit bind prompt.", color = TextMuted, fontSize = 12.sp)

                    if (targets.isNotEmpty()) {
                        SectionLabel("RECENT TARGETS")
                        targets.take(8).forEach { target ->
                            OutlinedCard(Modifier.fillMaxWidth().clickable { host = target.host; user = target.user; port = target.port.toString() }, shape = RoundedCornerShape(2.dp), border = BorderStroke(1.dp, GridLine), colors = CardDefaults.outlinedCardColors(containerColor = Panel)) {
                                Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Outlined.Dns, null, tint = Cyan); Spacer(Modifier.width(10.dp))
                                    Column { Text(target.label.ifBlank { target.host }, fontFamily = FontFamily.Monospace); Text(target.id, color = TextMuted, fontSize = 11.sp) }
                                }
                            }
                        }
                    }
                    SectionLabel("TARGET")
                    OutlinedTextField(host, { host = it }, Modifier.fillMaxWidth(), label = { Text("VPS IP / HOSTNAME") }, singleLine = true, isError = host.isNotBlank() && !Validation.validHost(host))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedTextField(user, { user = it }, Modifier.weight(1f), label = { Text("SSH USER") }, singleLine = true)
                        OutlinedTextField(port, { port = it.filter(Char::isDigit).take(5) }, Modifier.weight(1f), label = { Text("PORT") }, singleLine = true)
                    }
                    if (mode == AuthMode.TEMPORARY_PASSWORD) {
                        OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text("SSH PASSWORD (NOT SAVED)") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
                    }
                    Spacer(Modifier.height(8.dp))
                    Button(
                        onClick = { onLaunch(NodeTarget(host.trim(), user.trim(), port.toInt()), mode, password.takeIf { it.isNotBlank() }) },
                        enabled = valid && (mode == AuthMode.MANAGED_KEY || password.isNotBlank()),
                        modifier = Modifier.fillMaxWidth().height(54.dp),
                        shape = RoundedCornerShape(2.dp),
                    ) { Text(if (language == Language.ZH) "建立安全会话并执行" else "ESTABLISH SESSION + EXECUTE", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold) }
                }
            }
        }
    }
}

@Composable
private fun WorkflowScreen(state: WorkflowUiState, prompt: WorkflowPrompt?, tunnelUrl: String?, viewModel: AppViewModel) {
    val context = LocalContext.current
    var revealSecrets by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().background(Panel).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            val color = when (state.status) { RunStatus.FAILED -> Critical; RunStatus.SUCCEEDED -> Mint; RunStatus.CANCELLED -> Amber; else -> Cyan }
            Box(Modifier.size(9.dp).background(color)); Spacer(Modifier.width(9.dp))
            Column(Modifier.weight(1f)) {
                Text("${state.status} // OP:${state.action?.code ?: "--"}", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
                Text(state.target?.id.orEmpty(), color = TextMuted, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
            }
            if (state.status in setOf(RunStatus.CONNECTING, RunStatus.RUNNING, RunStatus.WAITING_INPUT)) {
                CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                IconButton(onClick = viewModel::cancelWorkflow) { Icon(Icons.Outlined.StopCircle, "Safe stop", tint = Critical) }
            }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth().background(Color(0xFF020609)).padding(horizontal = 13.dp), reverseLayout = true) {
            items(state.log.asReversed()) { line -> Text(line, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = TextPrimary, modifier = Modifier.padding(vertical = 1.dp)) }
        }
        state.error?.let { ErrorStrip(it) }
        state.downloadedFile?.let { path ->
            Row(Modifier.fillMaxWidth().background(PanelRaised).border(1.dp, Color(0xFFB997FF)).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("VERIFIED DOWNLOAD", color = Color(0xFFB997FF), fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
                    Text(File(path).name, color = TextMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
                }
                Button(onClick = {
                    val file = File(path)
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                    val share = Intent(Intent.ACTION_SEND).apply {
                        type = if (file.extension.equals("txt", true)) "text/plain" else "application/gzip"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(Intent.createChooser(share, "Export ${file.name}"))
                }, shape = RoundedCornerShape(2.dp)) { Text("EXPORT / SHARE") }
            }
        }
        state.secretHandoff?.let { secret ->
            Column(Modifier.fillMaxWidth().background(Panel).border(1.dp, Amber).padding(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.AdminPanelSettings, null, tint = Amber); Spacer(Modifier.width(8.dp)); Text("VERIFIED SECRET HANDOFF", color = Amber, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.weight(1f)); TextButton(onClick = { revealSecrets = !revealSecrets }) { Text(if (revealSecrets) "HIDE" else "REVEAL") }
                }
                if (revealSecrets) SelectionContainer { Text(secret, fontFamily = FontFamily.Monospace, fontSize = 10.sp, maxLines = 9, overflow = TextOverflow.Ellipsis) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { viewModel.copySecret(secret) }, shape = RoundedCornerShape(2.dp)) { Icon(Icons.Outlined.ContentCopy, null); Text(" COPY") }
                    OutlinedButton(onClick = viewModel::clearClipboard, shape = RoundedCornerShape(2.dp)) { Text("CLEAR CLIPBOARD") }
                }
            }
        }
        if (tunnelUrl != null) {
            Row(Modifier.fillMaxWidth().background(PanelRaised).border(1.dp, Mint).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("TUNNEL ACTIVE", color = Mint, fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f))
                TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(tunnelUrl))) }) { Icon(Icons.Outlined.OpenInBrowser, null); Text(" OPEN") }
                TextButton(onClick = viewModel::closeTunnel) { Text("CLOSE", color = Critical) }
            }
        }
        if (prompt != null) PromptPanel(prompt, viewModel::submitPrompt, viewModel::cancelWorkflow)
        else if (state.status in setOf(RunStatus.SUCCEEDED, RunStatus.FAILED, RunStatus.CANCELLED)) {
            Button(onClick = viewModel::clearWorkflow, modifier = Modifier.fillMaxWidth().padding(12.dp).height(48.dp), shape = RoundedCornerShape(2.dp)) { Text("RETURN TO CONTROL MATRIX") }
        }
    }
}

@Composable
private fun PromptPanel(prompt: WorkflowPrompt, submit: (String) -> Unit, cancel: () -> Unit) {
    var input by remember(prompt.id) { mutableStateOf(prompt.defaultValue) }
    Column(Modifier.fillMaxWidth().imePadding().background(Panel).border(1.dp, if (prompt.danger) Critical else GridLine).padding(12.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
        Text(prompt.title.uppercase(), color = if (prompt.danger) Critical else Cyan, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
        Text(prompt.message, color = TextPrimary, fontSize = 12.sp)
        if (prompt.kind == PromptKind.YES_NO) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { submit("y") }, shape = RoundedCornerShape(2.dp), modifier = Modifier.weight(1f)) { Text("YES / Y") }
                OutlinedButton(onClick = { submit("n") }, shape = RoundedCornerShape(2.dp), modifier = Modifier.weight(1f)) { Text("NO / N") }
                OutlinedButton(onClick = cancel, shape = RoundedCornerShape(2.dp)) { Text("STOP") }
            }
        } else {
            OutlinedTextField(
                value = input,
                onValueChange = { input = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text(prompt.placeholder) },
                visualTransformation = if (prompt.kind == PromptKind.SECRET) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
                singleLine = prompt.kind != PromptKind.TEXT,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { submit(input) }, modifier = Modifier.weight(1f), shape = RoundedCornerShape(2.dp)) { Text("SUBMIT") }
                OutlinedButton(onClick = cancel, shape = RoundedCornerShape(2.dp)) { Text("SAFE STOP") }
            }
        }
    }
}

@Composable
private fun KeysScreen(language: Language, keys: List<com.proxynodeassistant.android.model.ManagedKeyRecord>, viewModel: AppViewModel) {
    val context = LocalContext.current
    var showExportPassphrase by rememberSaveable { mutableStateOf(false) }
    var showImportPassphrase by rememberSaveable { mutableStateOf(false) }
    var exportPayload by remember { mutableStateOf<ByteArray?>(null) }
    var importPayload by remember { mutableStateOf<ByteArray?>(null) }
    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val payload = exportPayload
        if (uri != null && payload != null) runCatching { context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(payload) } }
            .onSuccess { viewModel.showMessage("Encrypted key backup exported") }
            .onFailure { viewModel.showMessage("Export failed: ${it.message}") }
        payload?.fill(0)
        exportPayload = null
    }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) runCatching {
            context.contentResolver.openInputStream(uri)!!.use { stream ->
                val bytes = stream.readBytes()
                require(bytes.size <= 5_000_000) { "Backup is larger than 5 MB" }
                bytes
            }
        }.onSuccess { importPayload = it; showImportPassphrase = true }
            .onFailure { viewModel.showMessage("Import read failed: ${it.message}") }
    }
    Column(Modifier.fillMaxSize()) {
        PageHeader("KEY VAULT", if (language == Language.ZH) "私钥经 Android Keystore 加密；备份态会空出绑定位置，远端公钥不自动删除。" else "Private keys are Keystore-encrypted. Backup state frees the bound slot without silently removing remote authorization.")
        Row(
            Modifier.padding(12.dp).horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            OutlinedButton(onClick = viewModel::archiveAllKeys, shape = RoundedCornerShape(2.dp)) { Text(if (language == Language.ZH) "全部转入备份态" else "ARCHIVE ALL") }
            OutlinedButton(onClick = { showExportPassphrase = true }, enabled = keys.isNotEmpty(), shape = RoundedCornerShape(2.dp)) { Text("EXPORT") }
            OutlinedButton(onClick = { importLauncher.launch(arrayOf("application/octet-stream", "application/zip", "*/*")) }, shape = RoundedCornerShape(2.dp)) { Text("IMPORT") }
        }
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(keys, key = { "${it.status}:${it.targetId}:${it.createdEpochMs}" }) { key ->
                OutlinedCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(2.dp), border = BorderStroke(1.dp, if (key.status == KeyStatus.BOUND) Mint else Amber), colors = CardDefaults.outlinedCardColors(containerColor = Panel)) {
                    Column(Modifier.padding(13.dp)) {
                        Row { Text(key.targetId, fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f)); Text(key.status.name, color = if (key.status == KeyStatus.BOUND) Mint else Amber, fontFamily = FontFamily.Monospace) }
                        Text(key.publicKeyOpenSsh.take(72) + "…", color = TextMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (key.status == KeyStatus.BOUND) OutlinedButton(onClick = { viewModel.archiveKey(key.targetId) }) { Text("TO BACKUP") }
                            else {
                                Button(onClick = { viewModel.restoreKey(key.targetId, key.createdEpochMs) }) { Text("RESTORE SLOT") }
                                TextButton(onClick = { viewModel.deleteBackup(key.targetId, key.createdEpochMs) }) { Text("DELETE", color = Critical) }
                            }
                        }
                    }
                }
            }
        }
    }
    if (showExportPassphrase) PassphraseDialog(
        title = if (language == Language.ZH) "导出加密密钥备份" else "EXPORT ENCRYPTED KEY BACKUP",
        confirmTwice = true,
        onDismiss = { showExportPassphrase = false },
        onConfirm = { passphrase ->
            runCatching { viewModel.exportKeyBackup(passphrase) }
                .onSuccess { exportPayload = it; showExportPassphrase = false; exportLauncher.launch("ProxyNodeAssistant-keys-v0.9.0.pnakeys") }
                .onFailure { viewModel.showMessage(it.message ?: "Key export failed") }
        },
    )
    if (showImportPassphrase) PassphraseDialog(
        title = if (language == Language.ZH) "解密并导入密钥备份" else "DECRYPT + IMPORT KEY BACKUP",
        confirmTwice = false,
        onDismiss = { importPayload?.fill(0); importPayload = null; showImportPassphrase = false },
        onConfirm = { passphrase ->
            val payload = importPayload ?: return@PassphraseDialog
            runCatching { viewModel.importKeyBackup(payload, passphrase) }
                .onSuccess { showImportPassphrase = false; importPayload?.fill(0); importPayload = null }
                .onFailure { viewModel.showMessage(it.message ?: "Key import failed") }
        },
    )
}

@Composable
private fun PassphraseDialog(title: String, confirmTwice: Boolean, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var first by remember { mutableStateOf("") }
    var second by remember { mutableStateOf("") }
    val valid = first.length >= 12 && (!confirmTwice || first == second)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, fontFamily = FontFamily.Monospace) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                Text("12+ characters. This passphrase is not stored and cannot be recovered.", color = TextMuted, fontSize = 12.sp)
                OutlinedTextField(first, { first = it }, Modifier.fillMaxWidth(), label = { Text("PASSPHRASE") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
                if (confirmTwice) OutlinedTextField(second, { second = it }, Modifier.fillMaxWidth(), label = { Text("CONFIRM PASSPHRASE") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
            }
        },
        confirmButton = { Button(onClick = { val value = first; first = ""; second = ""; onConfirm(value) }, enabled = valid) { Text(if (confirmTwice) "ENCRYPT + EXPORT" else "DECRYPT + IMPORT") } },
        dismissButton = { OutlinedButton(onClick = { first = ""; second = ""; onDismiss() }) { Text("CANCEL") } },
    )
}

@Composable
private fun HistoryScreen(language: Language, targets: List<NodeTarget>, viewModel: AppViewModel) {
    Column(Modifier.fillMaxSize()) {
        PageHeader("TARGET MEMORY", if (language == Language.ZH) "只保存 IP/主机名、用户、端口和标签；不保存密码。" else "Stores only host, user, port, and label; never passwords.")
        Row(Modifier.padding(12.dp)) { OutlinedButton(onClick = viewModel::clearTargets) { Icon(Icons.Outlined.Delete, null); Text(" CLEAR ALL") } }
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(targets, key = { it.id }) { target ->
                OutlinedCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(2.dp), colors = CardDefaults.outlinedCardColors(containerColor = Panel), border = BorderStroke(1.dp, GridLine)) {
                    Row(Modifier.fillMaxWidth().padding(13.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Dns, null, tint = Cyan); Spacer(Modifier.width(10.dp)); Column(Modifier.weight(1f)) { Text(target.label.ifBlank { target.host }, fontWeight = FontWeight.Bold); Text(target.id, color = TextMuted, fontFamily = FontFamily.Monospace, fontSize = 11.sp) }
                        IconButton(onClick = { viewModel.deleteTarget(target.id) }) { Icon(Icons.Outlined.Delete, "Delete", tint = Critical) }
                    }
                }
            }
        }
    }
}

@Composable
private fun LocalScreen(language: Language, tunnelUrl: String?, proxyEnabled: Boolean, proxyReachable: Boolean?, viewModel: AppViewModel) {
    val context = LocalContext.current
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        PageHeader("ANDROID LOCAL CONTROL", if (language == Language.ZH) "Android 不存在可由普通应用设置的 PowerShell 环境变量。本页只提供真实可生效的本应用代理目标和 SSH 隧道控制。" else "Android apps cannot set PowerShell-style global environment variables. This page exposes only real app-local proxy targets and SSH tunnel controls.")
        LocalBlock(
            "APP-LOCAL HTTP PROXY",
            "127.0.0.1:10808 // ${if (proxyEnabled) "ROUTING ENABLED" else "DIRECT"}",
            if (language == Language.ZH) "开启后，本应用的服务商 API 请求会通过 10808；SSH 不会被伪装成 HTTP 代理。监听状态必须实测。" else "When enabled, provider API requests from this app use 10808. SSH is never disguised as HTTP proxy. Listener status is measured.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    when (proxyReachable) { true -> "PROBE: LISTENING"; false -> "PROBE: CLOSED / UNREACHABLE"; null -> "PROBE: NOT CHECKED" },
                    color = when (proxyReachable) { true -> Mint; false -> Critical; null -> TextMuted },
                    fontFamily = FontFamily.Monospace,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { viewModel.setLocalProxyEnabled(!proxyEnabled) }) { Text(if (proxyEnabled) "USE DIRECT" else "ROUTE VIA 10808") }
                    OutlinedButton(onClick = viewModel::checkLocalProxy) { Text("CHECK PORT") }
                }
            }
        }
        LocalBlock("PANEL TUNNEL", tunnelUrl ?: "OFFLINE", if (tunnelUrl == null) "Start action 2 or open the panel at the end of action 1." else "The foreground service owns this connection; closing it is immediate and deterministic.") {
            if (tunnelUrl != null) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(tunnelUrl))) }) { Text("OPEN PANEL") }
                OutlinedButton(onClick = viewModel::closeTunnel) { Text("CLOSE TUNNEL", color = Critical) }
            }
        }
        LocalBlock("CLIPBOARD", "SECRET HYGIENE", if (language == Language.ZH) "只在本人点击复制时写入；建议粘贴进密码管理器后立刻清空。" else "Written only after an explicit copy; clear immediately after saving to a password manager.") {
            OutlinedButton(onClick = viewModel::clearClipboard) { Text("CLEAR CLIPBOARD") }
        }
    }
}

@Composable
private fun ProviderScreen(ui: AppUiState, viewModel: AppViewModel) {
    val language = ui.language
    var veid by rememberSaveable { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var rememberKey by rememberSaveable { mutableStateOf(false) }
    var warning by rememberSaveable(ui.providerWarningPercent) { mutableStateOf(ui.providerWarningPercent.toString()) }
    LaunchedEffect(ui.providerUsage) { if (ui.providerUsage != null) apiKey = "" }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        PageHeader("PROVIDER TRAFFIC", if (language == Language.ZH) "厂商 API 流量和 SSH/vnStat 是两条数据源；只有厂商 API 等同计费口径。" else "Provider API and SSH/vnStat are separate sources; only the provider API matches billing.")
        LocalBlock("KIWIVM", "VEID + PRIVATE API KEY", if (language == Language.ZH) "密钥默认只活在当前输入框；选中保存后，仅在成功查询后进入 Android Keystore 加密仓。请求体、界面日志和错误均不打印密钥。" else "The key is one-shot by default. With explicit save enabled it enters the Android Keystore vault only after a successful query. It is never printed in logs or errors.") {
            Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                OutlinedTextField(veid, { veid = it.filter(Char::isDigit).take(12) }, Modifier.fillMaxWidth(), label = { Text("VEID") }, singleLine = true)
                OutlinedTextField(apiKey, { apiKey = it.take(256) }, Modifier.fillMaxWidth(), label = { Text(if (language == Language.ZH) "API KEY（留空则尝试加密存档）" else "API KEY (BLANK = TRY VAULT)") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
                FilterChip(selected = rememberKey, onClick = { rememberKey = !rememberKey }, label = { Text(if (language == Language.ZH) "成功后加密保存此密钥" else "SAVE ENCRYPTED AFTER SUCCESS") }, leadingIcon = { Icon(Icons.Outlined.Lock, null, Modifier.size(16.dp)) })
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { viewModel.fetchKiwiUsage(veid, apiKey, rememberKey) }, enabled = !ui.providerLoading && veid.length >= 3, shape = RoundedCornerShape(2.dp)) { Text(if (ui.providerLoading) "QUERYING…" else "QUERY USAGE") }
                    OutlinedButton(onClick = { viewModel.forgetKiwiKey(veid); apiKey = "" }, enabled = veid.length >= 3, shape = RoundedCornerShape(2.dp)) { Text("FORGET KEY", color = Critical) }
                }
                if (ui.providerLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
                ui.providerError?.let { ErrorStrip(it) }
            }
        }
        LocalBlock("TRAFFIC WARNING", "${ui.providerWarningPercent}%", if (language == Language.ZH) "达到阈值时结果卡片转为黄色/红色；这是查询时预警，不在后台高频轮询厂商 API。" else "The result turns amber/red at the threshold. This is query-time warning and never an abusive high-frequency background poll.") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(warning, { warning = it.filter(Char::isDigit).take(3) }, Modifier.weight(1f), label = { Text("1-100 %") }, singleLine = true)
                OutlinedButton(onClick = { warning.toIntOrNull()?.let(viewModel::setProviderWarningPercent) }, enabled = warning.toIntOrNull() in 1..100) { Text("APPLY") }
            }
        }
        ui.providerUsage?.let { usage -> KiwiUsageBlock(usage, ui.providerWarningPercent) }
        LocalBlock("RACKNERD / OTHER PROVIDERS", "SSH / VNSTAT FALLBACK", if (language == Language.ZH) "RackNerd 套餐没有统一、稳定且每台都开放的计费 API 时，使用远端 vnStat 估算；界面会明确标记它不等同厂商账单。" else "When a RackNerd plan has no stable per-service billing API, use remote vnStat estimates; the UI explicitly marks that it is not provider billing.") {
            OutlinedButton(onClick = { viewModel.selectAction(ActionCatalog.byCode("17")) }) { Text("OPEN SSH / VNSTAT") }
        }
    }
}

@Composable
private fun KiwiUsageBlock(usage: KiwiUsage, warningPercent: Int) {
    val alert = usage.percent >= warningPercent
    val critical = usage.percent >= 95.0 || usage.suspended || usage.policyViolation
    val accent = when { critical -> Critical; alert -> Amber; else -> Mint }
    val locale = LocalLocale.current.platformLocale
    val reset = if (usage.resetEpochSeconds > 0) runCatching {
        SimpleDateFormat("yyyy-MM-dd HH:mm z", locale).format(Date(usage.resetEpochSeconds * 1000L))
    }.getOrDefault("UNKNOWN") else "UNKNOWN"
    OutlinedCard(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), shape = RoundedCornerShape(2.dp), border = BorderStroke(1.dp, accent), colors = CardDefaults.outlinedCardColors(containerColor = PanelRaised)) {
        Column(Modifier.padding(15.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row { Text("BILLING RESULT", color = accent, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Black); Spacer(Modifier.weight(1f)); Text(String.format(Locale.US, "%.1f%%", usage.percent), color = accent, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Black) }
            LinearProgressIndicator(progress = { usage.fraction.toFloat() }, modifier = Modifier.fillMaxWidth(), color = accent)
            Text("${formatGiB(usage.usedBytes)} / ${formatGiB(usage.allowanceBytes)}", fontFamily = FontFamily.Monospace, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Text("VEID=${usage.veid} // ${usage.hostname.ifBlank { "HOSTNAME UNKNOWN" }}", fontFamily = FontFamily.Monospace, fontSize = 11.sp)
            Text("${usage.plan.ifBlank { "PLAN UNKNOWN" }} // ${usage.location.ifBlank { "LOCATION UNKNOWN" }} // MULTIPLIER=${usage.multiplier}", color = TextMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
            Text("RESET=$reset // SUSPENDED=${usage.suspended} // POLICY_VIOLATION=${usage.policyViolation}", color = if (critical) Critical else TextMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
        }
    }
}

private fun formatGiB(value: Long): String = String.format(Locale.US, "%.2f GiB", value.toDouble() / 1_073_741_824.0)

@Composable
private fun AboutScreen(language: Language) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        PageHeader("BUILD 0.9.0 / ANDROID", if (language == Language.ZH) "原生 Kotlin + Compose；SSH 基于 ConnectBot 正式 sshlib；远端复用 proxy-runbook v0.9.0。" else "Native Kotlin + Compose; ConnectBot production sshlib; shared proxy-runbook v0.9.0 remote core.")
        LocalBlock("PRIVACY CONTRACT", "NO EMBEDDED TARGETS", "No real VPS IP, domain, email, password, API key, token, or private key is compiled into the APK.")
        LocalBlock("HOST KEY", "TOFU + PINNING", "First-use fingerprints require explicit TRUST. A changed key requires the distinct REPLACE confirmation and is saved only after a successful cryptographic handshake.")
        LocalBlock("FAIL CLOSED", "NO CHAINED SUCCESS", "Non-zero remote exit codes never trigger handoff copy or automatic panel opening. Structured metadata must pass marker and field validation.")
    }
}

@Composable
private fun PageHeader(code: String, description: String) {
    Column(Modifier.fillMaxWidth().background(Panel).border(0.5.dp, GridLine).padding(16.dp)) {
        Text(code, color = Cyan, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Black, letterSpacing = 1.sp)
        Spacer(Modifier.height(5.dp)); Text(description, color = TextMuted, fontSize = 12.sp)
    }
}

@Composable
private fun LocalBlock(code: String, value: String, description: String, content: @Composable (() -> Unit)? = null) {
    OutlinedCard(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), shape = RoundedCornerShape(2.dp), border = BorderStroke(1.dp, GridLine), colors = CardDefaults.outlinedCardColors(containerColor = Panel)) {
        Column(Modifier.padding(15.dp)) {
            Text(code, color = Cyan, fontFamily = FontFamily.Monospace, fontSize = 11.sp); Text(value, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold); Spacer(Modifier.height(5.dp)); Text(description, color = TextMuted, fontSize = 12.sp); content?.let { Spacer(Modifier.height(10.dp)); it() }
        }
    }
}

@Composable private fun SectionLabel(value: String) = Text("// $value", color = Cyan, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 11.sp)

@Composable
private fun ErrorStrip(error: String) { Text(error, color = Color.White, modifier = Modifier.fillMaxWidth().background(Critical).padding(10.dp), fontFamily = FontFamily.Monospace, fontSize = 11.sp) }
