import SwiftUI
import AppKit
import Combine
import Foundation

/// Owns the application-level shutdown handshake.  SwiftUI's `WindowGroup`
/// does not expose a reliable callback for a red-window close while a child
/// process is still attached to its PTY, so keep the bounded cleanup at the
/// AppKit boundary.  The model remains the source of truth for the running
/// process; this delegate only asks it to stop and replies to AppKit once the
/// normal termination handler (or the bounded fallback) has released the
/// pipes.
@MainActor
final class PNAApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationReplyPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.shared, model.operationRunning || model.hasManagedChildProcess else {
            return .terminateNow
        }

        // AppKit can ask more than once while the last window is closing.  A
        // single model request owns the timeout and invokes the callback once;
        // duplicate asks must keep waiting rather than start another Ctrl-C
        // sequence against the same PTY.
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        model.requestApplicationTermination { [weak self, weak sender] in
            guard let self else { return }
            self.terminationReplyPending = false
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// When the last SwiftUI window is closed, terminate only if an operation
    /// is active.  This routes a red-window close through the same bounded
    /// PTY/CLI cleanup while preserving the usual background app behavior when
    /// the workspace is idle.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let model = AppModel.shared else { return false }
        return model.operationRunning || model.hasManagedChildProcess
    }

    func applicationWillTerminate(_ notification: Notification) {
        // `applicationShouldTerminate` normally gets a chance to wait.  If
        // termination is forced by the system, still send SIGINT/SIGTERM to
        // the PTY relay so its child process group and any SSH tunnel receive
        // the cleanup signal before the app disappears.
        AppModel.shared?.forceTerminateForApplicationShutdown()
    }
}

@main
struct ProxyNodeAssistantApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(PNAApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, install, access, maintain, security, backup, local, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览 / 全部功能"
        case .install: return "安装与升级"
        case .access: return "面板与访问"
        case .maintain: return "维护与修复"
        case .security: return "安全与凭据"
        case .backup: return "备份与报告"
        case .local: return "本机工具"
        case .settings: return "设置"
        }
    }

    var eyebrow: String {
        switch self {
        case .overview: return "CONTROL MATRIX"
        case .install: return "INSTALLATION"
        case .access: return "ACCESS & HANDOFF"
        case .maintain: return "MAINTENANCE"
        case .security: return "SECURITY"
        case .backup: return "BACKUP & REPORTS"
        case .local: return "LOCAL TOOLS"
        case .settings: return "PREFERENCES"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "rectangle.3.group.fill"
        case .install: return "arrow.down.app.fill"
        case .access: return "rectangle.inset.filled.and.person.filled"
        case .maintain: return "wrench.and.screwdriver.fill"
        case .security: return "checkmark.shield.fill"
        case .backup: return "externaldrive.badge.checkmark"
        case .local: return "laptopcomputer"
        case .settings: return "gearshape.fill"
        }
    }

    var operationCategory: OperationCategory? {
        switch self {
        case .overview, .settings: return nil
        case .install: return .install
        case .access: return .access
        case .maintain: return .maintain
        case .security: return .security
        case .backup: return .backup
        case .local: return .local
        }
    }
}

enum OperationCategory: String, CaseIterable, Identifiable {
    case install, access, maintain, security, backup, local
    var id: String { rawValue }
}

struct OperationInfo: Identifiable, Hashable {
    let id: String
    let category: OperationCategory
    let title: String
    let description: String
    let symbol: String
    let tint: Color
}

struct RecentTarget: Identifiable, Hashable {
    let id = UUID()
    var host: String
    var user: String
    var port: String
    var display: String { "\(user)@\(host):\(port)" }

    var keyScope: String { "\(host) · \(user)" }
}

struct ManagedKeyEntry: Identifiable, Hashable {
    let id = UUID()
    var host: String
    var user: String
    var port: String
    var privatePath: String = ""
    var publicPath: String = ""

    var targetDisplay: String { "\(user)@\(host):\(port)" }
}

enum Topology: String, CaseIterable, Identifiable {
    case keep = "保持现有"
    case gray = "灰云直连"
    case orange = "橙云 CDN"
    case dual = "双路"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    /// The SwiftUI `App` owns the model, while the AppKit delegate receives
    /// application termination callbacks.  A weak bridge keeps that delegate
    /// from retaining the model (and therefore the view tree) during exit.
    static weak var shared: AppModel?

    @Published var section: AppSection = .overview
    @Published var topology: Topology = .dual
    @Published var performance = "标准"
    @Published var camouflage = "按域名稳定"
    @Published var warpEnabled = true
    @Published var planReady = false
    @Published var toast: String?

    @Published var selectedOperation: OperationInfo?
    @Published var workspacePresented = false
    @Published var operationRunning = false
    @Published var operationStatus = "等待启动"
    /// The log is rendered as selectable `Text` in the native UI.  Keep its
    /// setter private so no view can turn the log into an editable text area
    /// or inject untrusted content; the only public mutation is the explicit
    /// clear action below.
    @Published private(set) var operationLog = ""
    @Published var operationPrompt: String?
    @Published var operationSecretPrompt = false
    @Published var inputDraft = ""
    /// Operation [2] keeps its SSH port-forward process alive while the
    /// browser smoke test is running.  These flags are driven by the CLI's
    /// explicit tunnel status lines so the native workspace can always offer
    /// a matching close action instead of leaving the user with a hanging
    /// process and no way to finish it.
    @Published var panelTunnelActive = false
    @Published var panelLocalURL: String?
    /// The close request is sent as an empty answer to the CLI's framed
    /// keep-alive prompt. Keep it separate from `panelTunnelActive` so the
    /// button remains visible while the CLI is actually shutting down and
    /// can only be pressed once.
    @Published var panelTunnelClosing = false
    @Published var host = ""
    @Published var user = "root"
    @Published var port = "22"
    @Published var authMode = "临时密码"
    /// Optional one-shot SSH password entered in the native form. It is kept
    /// only in memory and cleared immediately after the CLI consumes it;
    /// it is never persisted, logged, or added to a process argument.
    @Published var passwordDraft = ""
    @Published var recentTargets: [RecentTarget] = []
    @Published var managedKeyEntries: [ManagedKeyEntry] = []
    @Published var connectionState = "未连接"
    @Published var activeTarget: RecentTarget?
    @Published var lastOperationTitle = ""
    @Published var lastOperationAt: Date?

    // The Darwin CLI announces that OpenSSH will read a password before the
    // OpenSSH child has actually opened its TTY. Keep the value queued until
    // the real `password:` prompt is visible; writing it earlier lets the
    // PTY's line discipline consume it (and can echo it into the log).
    private var awaitingSSHPassword = false
    private var sshPasswordPromptVisible = false
    private var queuedSSHPassword: String?

    /// Long lived SSH keys are owned by the bundled CLI and are scoped by
    /// VPS host plus SSH user. The GUI never reads private key material; it
    /// only keeps a non-secret target history and routes key management to
    /// the CLI's real [K] operation.
    var currentKeyScope: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else { return "等待填写主机和用户" }
        return trimmedHost + " · " + trimmedUser
    }

    /// The form can be edited after a previous node was selected. Keep the
    /// visible key binding scoped to the exact current endpoint so a key from
    /// another VPS can never be presented as the key for this connection.
    var currentManagedKey: ManagedKeyEntry? {
        managedKeyEntries.first { entry in
            keyScopeMatches(host: host, user: user,
                            entryHost: entry.host, entryUser: entry.user)
        }
    }

    /// Operations that stay entirely on this Mac do not need a VPS target or
    /// an SSH authentication form. Keep the distinction in the model so the
    /// launcher validation and the workspace layout cannot drift apart.
    var selectedOperationUsesSSH: Bool {
        guard let id = selectedOperation?.id else { return true }
        return !["K", "12", "14", "T", "H"].contains(id)
    }

    /// K is a mixed operation: listing/archiving keys is local, while restore
    /// and unbind can invoke OpenSSH and ask for a real password on its TTY.
    /// Keep the target form local-only for K, but still launch it through the
    /// PTY bridge so a later remote branch cannot fall back to a dead Pipe.
    /// This is deliberately separate from `selectedOperationUsesSSH`, which
    /// controls whether the form requires a target and whether a connection
    /// badge may be promoted.
    var selectedOperationMayUseSSH: Bool {
        guard let id = selectedOperation?.id else { return true }
        return !["12", "14", "T", "H"].contains(id)
    }

    private func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedUser(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedPort(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed).map(String.init) ?? trimmed
    }

    private func targetMatches(host: String, user: String, port: String,
                               entryHost: String, entryUser: String, entryPort: String) -> Bool {
        normalizedHost(host) == normalizedHost(entryHost)
            && normalizedUser(user) == normalizedUser(entryUser)
            && normalizedPort(port) == normalizedPort(entryPort)
    }

    /// The CLI stores one managed key per VPS host and SSH user. The SSH port
    /// is an endpoint detail and is intentionally excluded from key identity,
    /// so moving the same account to a non-default port still reuses its key.
    private func keyScopeMatches(host: String, user: String,
                                 entryHost: String, entryUser: String) -> Bool {
        normalizedHost(host) == normalizedHost(entryHost)
            && normalizedUser(user) == normalizedUser(entryUser)
    }

    /// Called whenever the connection form changes. `activeTarget` describes
    /// the last successful connection and must not remain attached to a newly
    /// typed VPS; otherwise the UI can show an old key while the CLI is being
    /// asked to authenticate a different host.
    func formTargetDidChange() {
        // A password entered for one endpoint must never follow the form to a
        // different endpoint. Clear both the visible one-shot field and any
        // password already queued behind an SSH prompt whenever target data
        // is edited.
        passwordDraft = ""
        queuedSSHPassword = nil
        guard let activeTarget else { return }
        guard targetMatches(host: host, user: user, port: port,
                            entryHost: activeTarget.host, entryUser: activeTarget.user, entryPort: activeTarget.port) else {
            self.activeTarget = nil
            if connectionState == "已连接" || connectionState == "最近连接" {
                connectionState = "未连接"
            }
            return
        }
    }

    let operations: [OperationInfo] = [
        OperationInfo(id: "1", category: .install, title: "安装 / 升级 / 自适应优化", description: "唯一安装入口；先预览、备份，精确输入 APPLY 才会施工。", symbol: "arrow.triangle.2.circlepath", tint: .pnaAccent),
        OperationInfo(id: "2", category: .access, title: "无感打开 3x-ui 面板", description: "通过 127.0.0.1 SSH 隧道打开后台，不暴露公网面板端口。", symbol: "rectangle.inset.filled.and.person.filled", tint: .pnaBlue),
        OperationInfo(id: "3", category: .maintain, title: "自动体检与排障", description: "结构化检查 SSH、x-ui、Nginx、WARP、订阅和端口状态。", symbol: "stethoscope", tint: .pnaGreen),
        OperationInfo(id: "4", category: .maintain, title: "安全自动修复", description: "先备份，再根据体检结果修复可自动处理的问题。", symbol: "wand.and.stars", tint: .pnaGreen),
        OperationInfo(id: "5", category: .security, title: "VPS 登录密码", description: "随机生成或遮罩输入自定义密码，输出经过校验的凭据交接单。", symbol: "key.fill", tint: .pnaOrange),
        OperationInfo(id: "6", category: .security, title: "3x-ui 账号密码", description: "随机或自定义面板身份；秘密只在本次 SSH 操作中使用。", symbol: "person.badge.key.fill", tint: .pnaOrange),
        OperationInfo(id: "7", category: .access, title: "显示当前凭据交接单", description: "读取真实面板元数据并在校验后显示或复制。", symbol: "doc.text.magnifyingglass", tint: .pnaBlue),
        OperationInfo(id: "8", category: .maintain, title: "切换 15 套伪装站", description: "随机、按域名稳定选择或指定模板，并优化 Nginx。", symbol: "sparkles.rectangle.stack", tint: .pnaGreen),
        OperationInfo(id: "9", category: .backup, title: "完整灾难恢复备份", description: "包含程序与远端节点配置，适合迁移或严重故障恢复。", symbol: "externaldrive.badge.timemachine", tint: .pnaPurple),
        OperationInfo(id: "10", category: .backup, title: "生成紧急诊断报告", description: "采集经过裁剪的故障证据并下载到当前电脑。", symbol: "doc.badge.gearshape", tint: .pnaPurple),
        OperationInfo(id: "11", category: .access, title: "绑定 / 重新生成 SSH key", description: "先验证新钥匙，再撤销旧公钥，避免把自己锁在 VPS 外。", symbol: "key.horizontal", tint: .pnaBlue),
        OperationInfo(id: "12", category: .local, title: "清空系统剪贴板", description: "立即清除可能仍包含密码或密钥的本地剪贴板。", symbol: "scissors", tint: .pnaMuted),
        OperationInfo(id: "13", category: .security, title: "卸载远端内嵌工具包", description: "只删除管理工具，保留节点、配置、凭据、证书与备份。", symbol: "trash.slash", tint: .pnaOrange),
        OperationInfo(id: "14", category: .local, title: "macOS 10808 系统代理", description: "保存原设置后，将 macOS 系统 HTTP/HTTPS/SOCKS 代理切换到 127.0.0.1:10808 并关闭 PAC/WPAD；可恢复原设置，仅需管理员授权，不连接 VPS。", symbol: "network", tint: .pnaMuted),
        OperationInfo(id: "15", category: .backup, title: "整理远端备份", description: "验证当前配置备份后，只清理本工具产生的冗余旧包。", symbol: "archivebox.fill", tint: .pnaPurple),
        OperationInfo(id: "16", category: .maintain, title: "自适应性能档位", description: "检测硬件后选择低配、标准、高配或自动档，支持回滚。", symbol: "gauge.with.dots.needle.33percent", tint: .pnaGreen),
        OperationInfo(id: "17", category: .maintain, title: "SSH / vnStat 流量估算", description: "通过 VPS 本地计数估算流量，并在 70/85/95% 分级预警。", symbol: "chart.xyaxis.line", tint: .pnaGreen),
        OperationInfo(id: "18", category: .security, title: "全量拆除与恢复基线", description: "高风险双重确认；先下载救援包，再恢复原始基线。", symbol: "exclamationmark.triangle.fill", tint: .pnaRed),
        OperationInfo(id: "19", category: .security, title: "识别本机 IP 并加入 SS2022 白名单", description: "核对本机与 VPS 看到的来源后，才添加精确 IPv4。", symbol: "checkmark.shield", tint: .pnaOrange),
        OperationInfo(id: "24", category: .security, title: "管理 SS2022 白名单", description: "查看当前精确 IPv4 白名单，自由添加或删除。", symbol: "list.bullet.rectangle", tint: .pnaOrange),
        OperationInfo(id: "20", category: .security, title: "访问与封禁日志", description: "聚合 SSH、防火墙、Nginx 和 Fail2ban 事件。", symbol: "list.bullet.clipboard", tint: .pnaOrange),
        OperationInfo(id: "22", category: .maintain, title: "CDN / XHTTP 线路控制中心", description: "灰云、橙云、双路的施工、验收、切换与回滚。", symbol: "point.3.connected.trianglepath.dotted", tint: .pnaAccent),
        OperationInfo(id: "23", category: .security, title: "更换公网 IP 后安全重绑定", description: "复用原 SSH key，身份不一致就停止，不盲目提交。", symbol: "arrow.triangle.branch", tint: .pnaPurple),
        OperationInfo(id: "T", category: .local, title: "服务商流量中心", description: "KiwiVM 精确 API、兼容 API 与系统凭据管理。", symbol: "chart.bar.xaxis", tint: .pnaMuted),
        OperationInfo(id: "K", category: .access, title: "管理已绑定节点 key", description: "查看、恢复或归档绑定位置，不自动填充秘密。", symbol: "archivebox", tint: .pnaBlue),
        OperationInfo(id: "H", category: .local, title: "管理 VPS 登录历史", description: "查看、删除单条或清空地址历史；不保存密码和 key。", symbol: "clock.arrow.circlepath", tint: .pnaMuted)
    ]

    private var toastTask: DispatchWorkItem?
    /// A credential handoff is copied to the system pasteboard before the
    /// CLI asks whether it may be cleared.  Keep that decision visible in the
    /// native UI long enough for the operator to paste into a password
    /// manager, then fail closed by clearing it automatically if the prompt
    /// is abandoned.  The timer is scoped to `operationGeneration` below so a
    /// delayed callback from an old operation can never clear a newer one.
    private let clipboardClearTimeoutSeconds: TimeInterval = 120
    private var clipboardClearTimeoutWork: DispatchWorkItem?
    private var process: Process?
    /// Processes that are winding down after the user switches workspaces or
    /// closes one.  A new operation may replace `process` before the old
    /// wrapper has delivered its termination callback; retain those old
    /// handles so app shutdown can still signal every child and never leave an
    /// orphaned PTY/SSH tunnel behind.
    private var retiringProcesses: [Process] = []
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    private var outputDataBuffer = Data()
    private var autoRoutingEnabled = false
    private var autoTargetValues: [String] = []
    private var pendingKeyMenuChoice: String?
    private var pendingManagedKeyIndex: Int?
    private var pendingUnbindTarget: ManagedKeyEntry?
    /// True only when a key-management card supplied an explicit managed-key
    /// target.  A generic K launch must not recycle the last VPS in the form
    /// as an implicit restore/unbind destination.
    private var keyManagementTargetProvided = false
    private var parsingManagedKeyList = false
    /// Set only after the current operation has emitted a durable SSH
    /// authentication marker.  A later action step (for example panel
    /// metadata) may fail while that authenticated session was valid; keep
    /// the connection badge in that case instead of reporting the node as
    /// disconnected.
    private var sshAuthenticatedForOperation = false
    private var operationGeneration = UUID()
    /// Set while AppKit is waiting for the PTY/CLI to stop.  The completion is
    /// consumed exactly once by `PNAApplicationDelegate`, either from the
    /// normal Process termination path or from the bounded shutdown fallback.
    private var applicationTerminationCompletion: (() -> Void)?
    private var applicationTerminationTimeoutWork: DispatchWorkItem?

    /// AppKit needs to wait for cleanup even when the visible operation state
    /// has already been reset while an earlier Process is still unwinding.
    var hasManagedChildProcess: Bool {
        process != nil || !retiringProcesses.isEmpty
    }

    init() {
        AppModel.shared = self
        let defaults = UserDefaults.standard
        if let savedData = defaults.data(forKey: "PNA.recentTargets"),
           let savedValues = try? JSONSerialization.jsonObject(with: savedData) as? [[String: String]] {
            recentTargets = savedValues.compactMap { value in
                guard let savedHost = value["host"], !savedHost.isEmpty,
                      let savedUser = value["user"], !savedUser.isEmpty,
                      let savedPort = value["port"], !savedPort.isEmpty else { return nil }
                return RecentTarget(host: savedHost, user: savedUser, port: savedPort)
            }
        }
        if let savedData = defaults.data(forKey: "PNA.managedKeyEntries"),
           let savedValues = try? JSONSerialization.jsonObject(with: savedData) as? [[String: String]] {
            managedKeyEntries = savedValues.compactMap { value in
                guard let savedHost = value["host"], !savedHost.isEmpty,
                      let savedUser = value["user"], !savedUser.isEmpty,
                      let savedPort = value["port"], !savedPort.isEmpty else { return nil }
                return ManagedKeyEntry(
                    host: savedHost,
                    user: savedUser,
                    port: savedPort,
                    privatePath: value["privatePath"] ?? "",
                    publicPath: value["publicPath"] ?? ""
                )
            }
        }
        // Recover bindings directly from the CLI's local metadata on launch.
        // The CLI is the source of truth for one key per host + user; relying
        // only on the GUI's UserDefaults made an existing key appear as
        // “当前目标未绑定” after reinstall or a failed previous refresh.
        // This reads metadata and file presence only, never private-key bytes.
        for discovered in discoverManagedKeyEntries() {
            if let index = managedKeyEntries.firstIndex(where: {
                keyScopeMatches(host: $0.host, user: $0.user,
                                entryHost: discovered.host, entryUser: discovered.user)
            }) {
                managedKeyEntries[index].port = discovered.port
                managedKeyEntries[index].privatePath = discovered.privatePath
                managedKeyEntries[index].publicPath = discovered.publicPath
            } else {
                managedKeyEntries.append(discovered)
            }
        }
        persistManagedKeyEntries()
        if let savedHost = defaults.string(forKey: "PNA.lastHost"), !savedHost.isEmpty {
            host = savedHost
            user = defaults.string(forKey: "PNA.lastUser") ?? "root"
            port = defaults.string(forKey: "PNA.lastPort") ?? "22"
            let target = RecentTarget(host: host, user: user, port: port)
            activeTarget = target
            if managedKeyEntries.contains(where: {
                keyScopeMatches(host: target.host, user: target.user,
                                entryHost: $0.host, entryUser: $0.user)
            }) {
                authMode = "节点长期 key"
            }
            if !recentTargets.contains(where: { $0.host == target.host && $0.user == target.user && $0.port == target.port }) {
                recentTargets.insert(target, at: 0)
            }
        }
        let savedState = defaults.string(forKey: "PNA.connectionState") ?? "未连接"
        // A relaunched app has no live SSH process, so a previous success is
        // shown as a recent target rather than falsely presented as online.
        connectionState = savedState == "已连接" ? "最近连接" : savedState
        lastOperationTitle = defaults.string(forKey: "PNA.lastOperationTitle") ?? ""
        lastOperationAt = defaults.object(forKey: "PNA.lastOperationAt") as? Date
    }

    private func discoverManagedKeyEntries() -> [ManagedKeyEntry] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("proxy-runbook", isDirectory: true)
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [ManagedKeyEntry] = []
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let infoURL = directory.appendingPathComponent("PNA-KEY-INFO.txt")
            let legacyInfoURL = directory.appendingPathComponent("TNA-KEY-INFO.txt")
            let infoText = (try? String(contentsOf: infoURL, encoding: .utf8))
                ?? (try? String(contentsOf: legacyInfoURL, encoding: .utf8))
            guard let infoText else { continue }
            var values: [String: String] = [:]
            for line in infoText.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                values[parts[0]] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // A restored working copy is deliberately marked BOUND_RESTORED
            // while its source backup remains retained under the recovery
            // directory.  It is still an active, usable node key and must be
            // discoverable after relaunch just like a freshly bound key.
            let status = values["STATUS"]?.uppercased()
            guard status == "BOUND" || status == "BOUND_RESTORED",
                  let hostData = Data(base64Encoded: values["HOST_B64"] ?? ""),
                  let userData = Data(base64Encoded: values["USER_B64"] ?? ""),
                  let host = String(data: hostData, encoding: .utf8),
                  let user = String(data: userData, encoding: .utf8),
                  !host.isEmpty, !user.isEmpty,
                  let portNumber = Int(values["PORT"] ?? ""),
                  (1...65535).contains(portNumber) else { continue }
            let privateURL = directory.appendingPathComponent("id_ed25519")
            let publicURL = directory.appendingPathComponent("id_ed25519.pub")
            guard fm.isReadableFile(atPath: privateURL.path),
                  fm.isReadableFile(atPath: publicURL.path) else { continue }
            result.append(ManagedKeyEntry(
                host: host,
                user: user,
                port: String(portNumber),
                privatePath: privateURL.path,
                publicPath: publicURL.path
            ))
        }
        return result
    }

    var selectedCategoryOperations: [OperationInfo] {
        guard let category = section.operationCategory else { return operations }
        return operations.filter { $0.category == category }
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        let task = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: task)
    }

    /// Exposed to `PromptPanel` so the handoff checkpoint can explain why the
    /// prompt is waiting and how long the bounded clipboard grace period is.
    var clipboardClearPromptVisible: Bool {
        isClipboardClearPrompt(operationPrompt)
    }

    var clipboardClearTimeoutLabel: String {
        String(Int(clipboardClearTimeoutSeconds))
    }

    private func isClipboardClearPrompt(_ prompt: String?) -> Bool {
        guard let prompt else { return false }
        let lowercasedPrompt = prompt.lowercased()
        return prompt.contains("清空含秘密的剪贴板")
            || lowercasedPrompt.contains("clear the secret-bearing clipboard")
    }

    private func cancelClipboardClearTimeout() {
        clipboardClearTimeoutWork?.cancel()
        clipboardClearTimeoutWork = nil
    }

    /// Keep the clear decision in the visible prompt instead of auto-answering
    /// it.  A bounded fallback still prevents a forgotten handoff from
    /// leaving credentials on the pasteboard indefinitely.
    private func armClipboardClearTimeout() {
        cancelClipboardClearTimeout()
        let operationToken = operationGeneration
        let timeout = clipboardClearTimeoutSeconds
        let work = DispatchWorkItem { [weak self] in
            // DispatchWorkItem may execute off the actor that owns the model;
            // hop back before inspecting or mutating SwiftUI state.
            Task { @MainActor [weak self] in
                guard let self,
                      self.operationGeneration == operationToken,
                      self.operationRunning,
                      self.clipboardClearPromptVisible else { return }
                self.operationStatus = "交接单确认超时，正在清空剪贴板"
                self.operationLog += "[PNA] 交接单确认超时，已自动清空秘密剪贴板。\n"
                self.sendInput("y")
            }
        }
        clipboardClearTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func openOperation(id: String) {
        cancelClipboardClearTimeout()
        if operationRunning || hasManagedChildProcess {
            stopOperation()
        }
        // Invalidate the old operation only after its stop request has
        // captured the current Process.  The retiring-process tracker below
        // continues to reap that handle even while this new workspace is
        // prepared.
        operationGeneration = UUID()
        selectedOperation = operations.first(where: { $0.id == id })
        sshAuthenticatedForOperation = false
        keyManagementTargetProvided = false
        workspacePresented = true
        operationRunning = false
        operationStatus = "准备执行"
        operationLog = ""
        operationPrompt = nil
        operationSecretPrompt = false
        panelTunnelActive = false
        panelLocalURL = nil
        panelTunnelClosing = false
        awaitingSSHPassword = false
        sshPasswordPromptVisible = false
        queuedSSHPassword = nil
        inputDraft = ""
        passwordDraft = ""
        autoRoutingEnabled = false
        autoTargetValues = []
        pendingKeyMenuChoice = nil
        pendingManagedKeyIndex = nil
        pendingUnbindTarget = nil
        parsingManagedKeyList = false
    }

    func openKeyManagement(choice: String? = nil, target: ManagedKeyEntry? = nil) {
        openOperation(id: "K")
        pendingKeyMenuChoice = choice
        pendingManagedKeyIndex = nil
        parsingManagedKeyList = false
        if let target {
            keyManagementTargetProvided = true
            host = target.host
            user = target.user
            port = target.port
            if choice == "2" {
                pendingUnbindTarget = target
            }
        }
        if choice == "1" {
            managedKeyEntries = []
        }
        guard choice != nil else { return }
        // Start on the next main run-loop turn so the workspace is presented
        // before the CLI's first menu prompt arrives.
        DispatchQueue.main.async { [weak self] in
            self?.startSelectedOperation()
        }
    }

    func openFullMenu() {
        if operationRunning || hasManagedChildProcess {
            stopOperation()
        }
        operationGeneration = UUID()
        selectedOperation = nil
        sshAuthenticatedForOperation = false
        keyManagementTargetProvided = false
        workspacePresented = true
        operationRunning = false
        operationStatus = "准备执行完整菜单"
        operationLog = ""
        operationPrompt = nil
        operationSecretPrompt = false
        panelTunnelActive = false
        panelLocalURL = nil
        panelTunnelClosing = false
        awaitingSSHPassword = false
        sshPasswordPromptVisible = false
        queuedSSHPassword = nil
        inputDraft = ""
        autoRoutingEnabled = false
        autoTargetValues = []
        pendingKeyMenuChoice = nil
        pendingManagedKeyIndex = nil
        pendingUnbindTarget = nil
    }

    func closeWorkspace() {
        if operationRunning || hasManagedChildProcess { stopOperation() }
        passwordDraft = ""
        workspacePresented = false
        selectedOperation = nil
    }

    func openCLI() { openFullMenu() }

    func startSelectedOperation() {
        guard !operationRunning else { return }
        let requiresSSH = selectedOperationUsesSSH
        let mayUseSSH = selectedOperationMayUseSSH
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requiresSSH || !normalizedHost.isEmpty else {
            operationStatus = "等待主机地址"
            showToast("先填写 VPS / 主机地址")
            return
        }
        guard !requiresSSH || !normalizedUser.isEmpty else {
            operationStatus = "等待 SSH 用户"
            showToast("先填写 SSH 用户")
            return
        }
        guard !requiresSSH || (Int(normalizedPort).map { (1...65535).contains($0) } ?? false) else {
            operationStatus = "等待有效端口"
            showToast("SSH 端口必须是 1—65535 的数字")
            return
        }
        host = normalizedHost
        user = normalizedUser
        if requiresSSH, let portNumber = Int(normalizedPort) {
            port = String(portNumber)
        }
        // A manually edited host/user/port is a new target. Clear the old
        // live target before starting so the connection pill and key selector
        // cannot continue to display the previous VPS while this one is
        // authenticating.
        if requiresSSH {
            activeTarget = nil
            connectionState = "连接中"
        }
        guard let binary = bundledCLIURL() else {
            operationStatus = "缺少随应用附带的 CLI"
            showToast("找不到 CLI 组件，请重新安装应用")
            return
        }

        // A workspace can be started more than once after a previous run has
        // finished.  Do not carry the previous run's authentication proof
        // into this new operation; it will be set again only by a fresh
        // durable SSH marker.
        sshAuthenticatedForOperation = false

        // A new run gets its own token. If a previous process is still
        // unwinding after Stop or switching operations, its termination
        // handler must not clear the state of this new run.
        let operationToken = UUID()
        operationGeneration = operationToken

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        // The Darwin CLI hands a VPS password to OpenSSH through its
        // controlling terminal. A plain Process/Pipe launch gives remote
        // actions a pipe instead of a TTY, so use the bundled forkpty relay
        // for every operation that may reach SSH. K is mixed: its list and
        // archive branches stay local, while restore/unbind need this same
        // controlling terminal. Truly local operations still use a direct
        // Pipe and avoid terminal buffering.
        if mayUseSSH {
            guard let bridge = bundledPTYBridgeURL() else {
                operationStatus = "缺少 PTY 组件"
                showToast("找不到 SSH 终端组件，请重新安装应用")
                return
            }
            child.executableURL = bridge
            child.arguments = [binary.path]
                + (selectedOperation.map { ["--gui-action", $0.id] } ?? [])
        } else {
            child.executableURL = binary
            child.arguments = selectedOperation.map { ["--gui-action", $0.id] } ?? []
        }
        child.environment = ProcessInfo.processInfo.environment.merging(["PNA_GUI_MODE": "1"]) { _, new in new }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stdout
        child.terminationHandler = { [weak self] task in
            Task { @MainActor in
                guard let self else { return }
                // Remove this handle from the retiring set before checking
                // the operation token.  A user may have switched to a new
                // workspace, in which case the old callback must still mark
                // its own Process as reaped even though it must not touch the
                // new operation's published state.
                self.removeRetiringProcess(task)
                guard self.operationGeneration == operationToken else { return }
                // `Process.terminationHandler` is not guaranteed to run on
                // every macOS launch path when the PTY relay exits during
                // startup.  The waitUntilExit fallback below may have
                // already finalized the operation; never run the cleanup
                // block twice or let a late callback overwrite a newer run.
                guard self.operationRunning else { return }
                self.flushOutputBuffer()
                self.operationRunning = false
                let output = self.operationLog
                // The parser normally records this as soon as the marker
                // arrives.  Re-check the final log as well so a very short
                // operation cannot lose an authentication proof in the race
                // between the last pipe read and Process termination.
                if self.containsDurableSSHMarker(output), self.selectedOperationUsesSSH {
                    self.sshAuthenticatedForOperation = true
                }
                let authenticatedAtTermination = self.sshAuthenticatedForOperation
                let tunnelCloseAck = self.selectedOperation?.id == "2"
                    && (output.range(of: "TNA_GUI_TUNNEL_CLOSE_ACK", options: [.caseInsensitive]) != nil
                        || output.range(of: "PNA_GUI_TUNNEL_CLOSE_ACK", options: [.caseInsensitive]) != nil)
                if (output.contains("Permission denied") || output.contains("publickey,password")),
                   !authenticatedAtTermination {
                    self.operationStatus = "认证失败"
                    self.connectionState = "认证失败"
                    self.showToast(output.contains("尚无长期 key")
                        ? "当前 VPS 没有已绑定 key，且初始密码认证失败"
                        : "SSH 认证失败，请检查当前目标的密码或 key")
                } else if output.contains("操作未完成") || output.contains("已取消") || output.contains("SSH 未就绪") {
                    self.operationStatus = output.contains("已取消") ? "已取消" : "未完成"
                } else {
                    self.operationStatus = task.terminationStatus == 0 ? "已完成" : "已停止（退出码 \(task.terminationStatus)）"
                }
                if tunnelCloseAck && task.terminationStatus == 0 {
                    self.operationStatus = "面板隧道已关闭"
                }
                self.cancelClipboardClearTimeout()
                self.operationPrompt = nil
                self.operationSecretPrompt = false
                self.panelTunnelActive = false
                self.panelLocalURL = nil
                self.panelTunnelClosing = false
                self.awaitingSSHPassword = false
                self.sshPasswordPromptVisible = false
                self.queuedSSHPassword = nil
                self.inputDraft = ""
                self.passwordDraft = ""
                self.autoRoutingEnabled = false
                self.autoTargetValues = []
                self.pendingKeyMenuChoice = nil
                self.pendingManagedKeyIndex = nil
                self.parsingManagedKeyList = false
                if task.terminationStatus == 0,
                   let target = self.pendingUnbindTarget,
                   !output.contains("已取消"),
                   !output.contains("未完成") {
                    self.managedKeyEntries.removeAll {
                        $0.host == target.host && $0.user == target.user && $0.port == target.port
                    }
                    self.persistManagedKeyEntries()
                }
                // A successful bind/rebind, or a verified managed-key login,
                // proves that this host + user owns a managed key.  Keep the
                // native list in sync immediately even when a later step of
                // the same action fails (for example panel metadata timing
                // out after the key was accepted).  Paths remain blank until
                // the next K→1 refresh because the CLI intentionally does not
                // expose private-key material through its success marker.
                // `TEMPORARY_SSH_KEY_OK` intentionally contains the substring
                // `SSH_KEY_OK`; it only proves that a one-use key was
                // installed for this action and must never create a durable
                // entry in the native multi-key list.  Require the explicit
                // managed-key marker or the localized bind confirmation.
                let keyBound = output.range(of: "key is now bound", options: [.caseInsensitive]) != nil
                    || output.contains("已绑定为")
                    || output.contains("已绑定 SSH 登录密钥")
                    || output.contains("SSH_KEY_OK：已使用")
                    || output.contains("SSH_KEY_OK: the managed key")
                if keyBound && self.selectedOperationUsesSSH {
                    // A first long-key login promotes the verified temporary
                    // session and may not emit the later SSH_KEY_OK marker.
                    // The explicit bind confirmation is nevertheless a
                    // durable success signal, so update the visible host
                    // badge immediately; a later action failure will clear it
                    // through the normal operationFailed path below.
                    self.markConnected()
                }
                if keyBound && self.selectedOperationUsesSSH,
                   !self.host.isEmpty,
                   !self.user.isEmpty,
                   !self.managedKeyEntries.contains(where: {
                       self.keyScopeMatches(host: self.host, user: self.user,
                                            entryHost: $0.host, entryUser: $0.user)
                   }) {
                    self.managedKeyEntries.append(ManagedKeyEntry(host: self.host, user: self.user, port: self.port))
                    self.persistManagedKeyEntries()
                }
                self.pendingUnbindTarget = nil
                let operationFailed = task.terminationStatus != 0
                    || output.contains("操作未完成")
                    || output.contains("SSH 未就绪")
                    || output.contains("无法读取 panel")
                if operationFailed {
                    if authenticatedAtTermination, self.activeTarget != nil {
                        // Authentication is a useful, independent result:
                        // panel metadata or a later remote command can time
                        // out without invalidating the SSH credential. Keep
                        // the host pill visible and put the follow-up failure
                        // in the operation status/log instead.
                        self.connectionState = "已连接"
                        self.operationStatus = "已连接 · 后续步骤失败"
                    } else {
                        if self.connectionState != "认证失败" {
                            self.connectionState = "上次失败"
                        }
                        self.activeTarget = nil
                    }
                }
                self.process = nil
                self.inputPipe = nil
                self.outputPipe = nil
                self.completeApplicationTermination()
            }
        }

        outputPipe = stdout
        inputPipe = stdin
        outputBuffer = ""
        outputDataBuffer = Data()
        // Initialize the visible run state before launching the child.  The
        // CLI writes its first framed prompt immediately; if that output is
        // delivered while `child.run()` is returning, assigning
        // `operationLog` afterwards can erase the prompt and leave the CLI
        // waiting forever with the UI showing only "正在运行".
        operationLog = "[PNA] 已在原生窗口启动 \(selectedOperation?.title ?? "完整菜单")\n[PNA] 远端变更仍由 CLI 的安全流程负责。\n\n"
        operationStatus = "正在运行"
        operationRunning = true
        // Feed the same non-secret answers the Windows GUI sends through its
        // prompt broker. Passwords and other secrets remain manual prompts.
        autoRoutingEnabled = selectedOperation != nil
        // K contains both local-only and remote subcommands.  Keep automatic
        // target routing for a card action that supplied a concrete managed
        // key, but leave a generic K launch fully manual so stale form values
        // can never be sent as a new VPS target.
        autoTargetValues = selectedOperation?.id == "K" && !keyManagementTargetProvided
            ? []
            : [host, user, port]
        // Read the pipe on a dedicated blocking reader. FileHandle's
        // readabilityHandler is tied to a run-loop source and can fail to
        // deliver the first PTY chunk in a SwiftUI app even though the child
        // process is healthy. A blocking read is deterministic: every byte
        // written by the bundled PTY bridge is forwarded to AppModel in
        // order, then EOF is reported once the bridge exits.
        let outputHandle = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                // `readData(ofLength:)` on macOS can wait for the requested
                // length instead of returning the bytes that are already
                // available.  The CLI's first framed prompt is usually much
                // smaller than 8192 bytes and then waits for our answer,
                // which made the reader and CLI deadlock. `availableData`
                // returns as soon as one output chunk arrives and still
                // yields an empty Data at EOF.
                let data = outputHandle.availableData
                guard !data.isEmpty else { break }
                // Hop explicitly to the model's global actor.  A plain
                // DispatchQueue.main.async closure can be deferred behind
                // SwiftUI's event transaction while a PTY child is waiting
                // for input, so the bytes are read but the prompt never
                // reaches the published UI state.
                Task { @MainActor [weak self] in
                    // A stop/switch can leave bytes queued in the old PTY
                    // pipe.  Ignore those late chunks once a new operation
                    // generation has started; otherwise an old prompt or
                    // success marker can be applied to the new target.
                    guard let self,
                          self.operationGeneration == operationToken,
                          self.operationRunning else { return }
                    self.consumeOutput(data)
                }
            }
        }

        do {
            // Publish the Process handle before launching.  The first PTY
            // frame can arrive immediately; prompt routing and password
            // submission must see a live process even while run() returns.
            process = child
            try child.run()
            // Keep an independent wait path for the native Process wrapper.
            // On some macOS releases a forkpty child can disappear before
            // Foundation delivers terminationHandler, leaving the SwiftUI
            // state stuck at “运行中” with no child process left to stop.
            // waitUntilExit is performed off the main actor and only the
            // still-current operation token may be finalized.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                child.waitUntilExit()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Foundation can omit `terminationHandler` for a very
                    // short-lived forkpty wrapper.  The independent wait
                    // path is also responsible for releasing a stale handle
                    // that belongs to an earlier workspace generation.
                    self.removeRetiringProcess(child)
                    guard self.operationGeneration == operationToken,
                          self.operationRunning else { return }
                    self.finishOperationAfterUnexpectedExit(task: child)
                }
            }
            if requiresSSH {
                connectionState = "连接中"
            }
        } catch {
            removeRetiringProcess(child)
            process = nil
            operationRunning = false
            operationStatus = "启动失败"
            showToast("CLI 启动失败：\(error.localizedDescription)")
        }
    }

    /// Fallback for a Process that has exited but whose terminationHandler
    /// was not delivered by Foundation.  This path deliberately mirrors the
    /// visible state reset in the normal handler and never performs remote
    /// work; the CLI/PTY process has already exited at this point.
    private func finishOperationAfterUnexpectedExit(task: Process) {
        guard operationRunning else { return }
        removeRetiringProcess(task)
        flushOutputBuffer()
        operationRunning = false
        let output = operationLog
        let status = task.terminationStatus
        let keyBound = output.range(of: "key is now bound", options: [.caseInsensitive]) != nil
            || output.contains("已绑定为")
            || output.contains("已绑定 SSH 登录密钥")
            || output.contains("SSH_KEY_OK：已使用")
            || output.contains("SSH_KEY_OK: the managed key")
        if keyBound && selectedOperationUsesSSH {
            markConnected()
        }
        if containsDurableSSHMarker(output), selectedOperationUsesSSH {
            sshAuthenticatedForOperation = true
        }
        let authenticatedAtExit = sshAuthenticatedForOperation
        if (output.contains("Permission denied") || output.contains("publickey,password")),
           !authenticatedAtExit {
            operationStatus = "认证失败"
            connectionState = "认证失败"
        } else if output.contains("操作未完成") || output.contains("已取消") || output.contains("SSH 未就绪") {
            operationStatus = output.contains("已取消") ? "已取消" : "未完成"
        } else {
            operationStatus = status == 0 ? "已完成" : "已停止（退出码 \(status)）"
        }
        let operationFailed = status != 0
            || output.contains("操作未完成")
            || output.contains("SSH 未就绪")
            || output.contains("无法读取 panel")
        if operationFailed {
            if authenticatedAtExit, activeTarget != nil {
                connectionState = "已连接"
                operationStatus = "已连接 · 后续步骤失败"
            } else if connectionState != "认证失败" {
                connectionState = "上次失败"
                activeTarget = nil
            }
        }
        cancelClipboardClearTimeout()
        operationPrompt = nil
        operationSecretPrompt = false
        panelTunnelActive = false
        panelLocalURL = nil
        panelTunnelClosing = false
        awaitingSSHPassword = false
        sshPasswordPromptVisible = false
        queuedSSHPassword = nil
        inputDraft = ""
        passwordDraft = ""
        autoRoutingEnabled = false
        autoTargetValues = []
        pendingKeyMenuChoice = nil
        pendingManagedKeyIndex = nil
        parsingManagedKeyList = false
        pendingUnbindTarget = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        completeApplicationTermination()
    }

    func sendInput(_ value: String? = nil) {
        // The PTY relay can publish a framed prompt in the same scheduling
        // window in which Process.run() is still returning.  The input pipe
        // is already valid at that point, while Process.isRunning may still
        // report false; gating on the latter drops the answer and strands the
        // CLI at a required prompt.  The operation token and pipe lifetime
        // are the authoritative guards here.
        guard operationRunning, let inputPipe else { return }
        let valueToSend = value ?? inputDraft

        // Keep a manually entered password in memory until OpenSSH's actual
        // prompt appears on the PTY. This covers the case where the user
        // clicks Submit quickly after the CLI's announcement line.
        if operationSecretPrompt, awaitingSSHPassword {
            queuedSSHPassword = valueToSend
            inputDraft = ""
            // The real OpenSSH password prompt has no trailing newline.  It
            // can already be buffered by consumeOutput when the user finishes
            // typing in the lower masked field, so there may be no later PTY
            // bytes to trigger submitQueuedSSHPasswordIfPromptVisible().
            // Re-check synchronously after queueing to avoid leaving ssh
            // parked forever at `password:`.
            submitQueuedSSHPasswordIfPromptVisible()
            return
        }

        writeInput(valueToSend, through: inputPipe)
    }

    private func writeInput(_ value: String, through inputPipe: Pipe) {
        let wasClipboardClearPrompt = isClipboardClearPrompt(operationPrompt)
        if wasClipboardClearPrompt {
            cancelClipboardClearTimeout()
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "y" || normalized == "yes" || normalized == "是" {
                operationStatus = "正在清空交接单剪贴板"
                operationLog += "[PNA] 已确认清空秘密剪贴板。\n"
            } else if normalized == "n" || normalized == "no" || normalized == "否" {
                operationStatus = "交接单已保留在剪贴板"
                operationLog += "[PNA] 已选择暂不清空秘密剪贴板；请在密码管理器保存后手动清理。\n"
            }
        }
        let data = (value + "\n").data(using: .utf8) ?? Data()
        inputPipe.fileHandleForWriting.write(data)
        inputDraft = ""
        if operationSecretPrompt {
            passwordDraft = ""
        }
        if awaitingSSHPassword {
            awaitingSSHPassword = false
            sshPasswordPromptVisible = false
            queuedSSHPassword = nil
        }
        operationPrompt = nil
        operationSecretPrompt = false
    }

    /// Submit a password entered in the connection form after an operation
    /// has already reached OpenSSH's password hand-off announcement.  The
    /// form is intentionally usable both before and during a run; when the
    /// field is edited during a run, SwiftUI must provide an explicit commit
    /// point instead of sending every keystroke as a partial password.
    func submitPasswordDraft() {
        guard operationRunning, awaitingSSHPassword, !passwordDraft.isEmpty else { return }
        queuedSSHPassword = passwordDraft
        passwordDraft = ""
        submitQueuedSSHPasswordIfPromptVisible()
    }

    private func sendAutomaticInput(_ value: String, note: String) {
        guard operationRunning else { return }
        operationLog += "[PNA] " + note + "\n"
        sendInput(value)
    }

    private func trackRetiringProcess(_ process: Process) {
        guard !retiringProcesses.contains(where: { $0 === process }) else { return }
        retiringProcesses.append(process)
    }

    private func removeRetiringProcess(_ process: Process) {
        retiringProcesses.removeAll { $0 === process }
    }

    private func signalProcessForShutdown(_ process: Process) {
        process.interrupt()
        process.terminate()
    }

    /// Ask the current CLI/PTY operation to stop before AppKit tears down the
    /// process.  The normal stop path gets a short grace period to let the
    /// CLI revoke temporary keys and close an SSH tunnel; after that bounded
    /// window we signal the PTY relay directly and release the termination
    /// reply so a wedged remote connection can never block app quit forever.
    func requestApplicationTermination(completion: @escaping () -> Void) {
        guard operationRunning else {
            completion()
            return
        }

        // AppKit may deliver duplicate termination requests while a window is
        // closing.  Keep the first completion (owned by the delegate) and let
        // its callback reply once the operation has actually been reaped.
        guard applicationTerminationCompletion == nil else { return }
        applicationTerminationCompletion = completion

        guard process != nil || !retiringProcesses.isEmpty else {
            operationRunning = false
            inputPipe = nil
            outputPipe = nil
            completeApplicationTermination()
            return
        }

        if process != nil {
            stopOperation()
        } else {
            // The visible operation may already have handed its Process
            // reference to the retiring set while a new workspace is being
            // prepared.  There is no current stdin pipe to send Ctrl-C to,
            // so signal every retained wrapper immediately.
            forceTerminateForApplicationShutdown()
        }
        let timeout = DispatchWorkItem { [weak self] in
            // DispatchWorkItem executes outside the main actor.  Hop back
            // explicitly before touching the model or Process handle.
            Task { @MainActor [weak self] in
                guard let self, self.applicationTerminationCompletion != nil else { return }
                self.forceTerminateForApplicationShutdown()
                // The PTY bridge normally exits immediately after SIGTERM and
                // its termination handler will complete the request.  Keep a
                // final one-second bound for a bridge that cannot report EOF;
                // AppKit must still be allowed to finish termination.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.applicationTerminationCompletion != nil else { return }
                    self.completeApplicationTermination()
                }
            }
        }
        applicationTerminationTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: timeout)
    }

    /// Called by the normal Process termination handler and its waitUntilExit
    /// fallback.  Cancellation makes the timeout harmless, and clearing the
    /// callback before invoking it guarantees that a late termination event
    /// cannot reply to AppKit twice.
    private func completeApplicationTermination() {
        applicationTerminationTimeoutWork?.cancel()
        applicationTerminationTimeoutWork = nil
        let completion = applicationTerminationCompletion
        applicationTerminationCompletion = nil
        completion?()
    }

    /// Send signals to the PTY relay.  `pna-pty-bridge` forwards SIGINT,
    /// SIGTERM and SIGHUP to the CLI's process group, which in turn closes any
    /// SSH control master/port-forward and runs its deferred temporary-key
    /// cleanup.  This method is also safe to call from `applicationWillTerminate`
    /// if AppKit has to force termination before the normal reply arrives.
    func forceTerminateForApplicationShutdown() {
        if let process {
            signalProcessForShutdown(process)
        }
        for retiring in retiringProcesses {
            // A Process may be present in both collections during the short
            // handoff between stop and termination; duplicate signals are
            // harmless, but avoid them to keep the shutdown path quiet.
            if let process, retiring === process { continue }
            signalProcessForShutdown(retiring)
        }
    }

    func stopOperation() {
        cancelClipboardClearTimeout()
        guard let process else {
            forceTerminateForApplicationShutdown()
            return
        }
        trackRetiringProcess(process)
        // script owns the PTY foreground process group. Send Ctrl-C first so
        // the CLI can run its normal deferred cleanup, then terminate the
        // wrapper if it has not exited yet.
        inputPipe?.fileHandleForWriting.write(Data([0x03]))
        operationStatus = "正在安全停止"
        operationPrompt = nil
        operationSecretPrompt = false
        awaitingSSHPassword = false
        sshPasswordPromptVisible = false
        queuedSSHPassword = nil
        inputDraft = ""
        passwordDraft = ""
        let processToStop = process
        // Give the CLI enough time for its remote revoke and local key
        // deletion round trips on a high-latency VPS; only force-stop after
        // the cleanup window expires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self else { return }
            // Do not gate on `operationRunning`: switching to another card
            // intentionally resets that flag while this old Process is still
            // unwinding.  Identity checks keep the delayed stop from ever
            // killing a newer operation's Process.
            guard self.retiringProcesses.contains(where: { $0 === processToStop })
                || self.process === processToStop else { return }
            self.signalProcessForShutdown(processToStop)
        }
    }

    /// Finish operation [2] through the CLI's graphical tunnel handshake.
    /// After the forwarding socket is ready the CLI enters a framed prompt
    /// and deliberately expects an empty answer (the user presses Enter).
    /// It then emits `PNA_GUI_TUNNEL_CLOSE_ACK` (the newer CLI source calls
    /// the compatible marker `TNA_GUI_TUNNEL_CLOSE_ACK`), tears down every forwarding
    /// process and runs its normal temporary-key cleanup. Sending the marker
    /// as text would be interpreted as a non-empty answer and make the CLI
    /// report a failed smoke test, so this must go through `writeInput("")`.
    func closePanelTunnel() {
        guard selectedOperation?.id == "2", operationRunning,
              panelTunnelActive, !panelTunnelClosing,
              let inputPipe else { return }
        operationLog += "[PNA] 正在关闭面板隧道…\n"
        panelTunnelClosing = true
        operationStatus = "正在关闭面板隧道"
        // The CLI's hold prompt treats an empty line as the close command.
        writeInput("", through: inputPipe)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.operationRunning, self.selectedOperation?.id == "2" else { return }
            self.operationLog += "[PNA] CLI 未在 5 秒内确认隧道关闭，执行安全停止。\n"
            self.stopOperation()
        }
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(operationLog, forType: .string)
        showToast("日志已复制；如果其中包含交接信息，请保存后清空剪贴板")
    }

    func clearOperationLog() {
        operationLog = ""
    }

    func makePlan() {
        planReady = true
        showToast("施工预览已生成，确认无误后再运行安装操作")
    }

    func selectRecentTarget(_ target: RecentTarget) {
        host = target.host
        user = target.user
        port = target.port
        activeTarget = target
        if managedKeyEntries.contains(where: {
            keyScopeMatches(host: target.host, user: target.user,
                            entryHost: $0.host, entryUser: $0.user)
        }) {
            authMode = "节点长期 key"
        }
        connectionState = "最近连接"
        showToast("已载入 " + target.display + "；认证 key 将按该主机和用户独立查找")
    }

    func selectManagedKey(_ entry: ManagedKeyEntry) {
        host = entry.host
        user = entry.user
        port = entry.port
        authMode = "节点长期 key"
        activeTarget = RecentTarget(host: entry.host, user: entry.user, port: entry.port)
        connectionState = "最近连接"
        showToast("已选择绑定 key：" + entry.targetDisplay)
    }

    func uninstallApplication() {
        let appPath = Bundle.main.bundleURL.path
        let homeApplications = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications").path
        guard appPath.hasPrefix(homeApplications + "/") else {
            showToast("当前应用装在系统 Applications；请使用用户级安装包后再卸载")
            return
        }

        // A previous [14] run may have taken ownership of the macOS system
        // proxy and left a verified restore snapshot beside the app. Restore
        // that snapshot before deleting the app data; otherwise an uninstall
        // would remove the only recovery record and strand 127.0.0.1:10808 in
        // the user's network settings. The bundled CLI invokes Apple's own
        // administrator dialog when the snapshot exists, then we continue
        // with the same user-level file cleanup as before.
        let restoreState = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ProxyNodeAssistant/local-proxy-state.json")
        if FileManager.default.fileExists(atPath: restoreState.path) {
            guard let cli = bundledCLIURL() else {
                showToast("找不到本地代理恢复组件；为避免留下系统代理，暂不卸载")
                return
            }
            let restore = Process()
            let restoreOutput = Pipe()
            restore.executableURL = cli
            restore.arguments = ["--restore-local-proxy"]
            restore.environment = ProcessInfo.processInfo.environment.merging(["PNA_GUI_MODE": "1"]) { _, new in new }
            restore.standardOutput = restoreOutput
            restore.standardError = restoreOutput
            showToast("正在恢复 macOS 系统代理，完成后继续卸载")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try restore.run()
                    restore.waitUntilExit()
                    let status = restore.terminationStatus
                    let output = String(data: restoreOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard status == 0 else {
                            self.operationLog += "[PNA] 系统代理恢复失败，已停止卸载：\n" + output
                            self.showToast("系统代理恢复失败，未删除应用；请重试")
                            return
                        }
                        self.finishApplicationUninstall(appPath: appPath)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.operationLog += "[PNA] 系统代理恢复启动失败，已停止卸载：\n\(error.localizedDescription)\n"
                        self.showToast("系统代理恢复启动失败，未删除应用")
                    }
                }
            }
            return
        }

        finishApplicationUninstall(appPath: appPath)
    }

    private func finishApplicationUninstall(appPath: String) {
        let escapedApp = appPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/zsh\nsleep 1\n/bin/rm -rf -- '\(escapedApp)'\n/bin/rm -rf -- \"$HOME/Library/Application Support/ProxyNodeAssistant\" \"$HOME/Library/Caches/com.greyoak111.proxynodeassistant\" \"$HOME/Library/Logs/ProxyNodeAssistant\" \"$HOME/Library/Saved Application State/com.greyoak111.proxynodeassistant.savedState\"\n/bin/rm -f -- \"$HOME/Library/Preferences/com.greyoak111.proxynodeassistant.plist\"\n/usr/bin/defaults delete com.greyoak111.proxynodeassistant >/dev/null 2>&1 || true\n/usr/sbin/pkgutil --volume \"$HOME\" --forget com.greyoak111.proxynodeassistant >/dev/null 2>&1 || true\n/bin/rm -f -- \"$0\"\n"
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pna-uninstall-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/zsh")
            child.arguments = [scriptURL.path]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            showToast("正在卸载，应用即将退出")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        } catch {
            showToast("卸载启动失败：\(error.localizedDescription)")
        }
    }

    private func bundledCLIURL() -> URL? {
        guard let url = Bundle.main.url(forResource: "ProxyNodeAssistant-cli", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private func bundledPTYBridgeURL() -> URL? {
        guard let url = Bundle.main.url(forResource: "pna-pty-bridge", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private func consumeOutput(_ data: Data) {
        // Pipe reads can split a multi-byte UTF-8 character at the chunk
        // boundary. Keep only the incomplete suffix until the next read. A
        // whole-buffer `String(data:encoding:)` guard is unsafe here: when a
        // Chinese character is split at the end of the first chunk, the CLI
        // is already waiting for our answer and will never produce another
        // chunk, leaving the GUI permanently at "等待 CLI 提示…".
        outputDataBuffer.append(data)
        let raw = [UInt8](outputDataBuffer)
        var decodableCount = raw.count
        if !raw.isEmpty {
            // Count continuation bytes at the end and inspect their lead
            // byte. Only preserve the lead + continuations when the expected
            // UTF-8 sequence is genuinely incomplete; malformed bytes are
            // decoded as replacement characters so they cannot deadlock the
            // prompt broker.
            var continuationStart = raw.count
            while continuationStart > 0,
                  (raw[continuationStart - 1] & 0xC0) == 0x80 {
                continuationStart -= 1
            }
            if continuationStart > 0 {
                let leadIndex = continuationStart - 1
                let lead = raw[leadIndex]
                let expectedLength: Int
                if lead <= 0x7F {
                    expectedLength = 1
                } else if (lead & 0xE0) == 0xC0 {
                    expectedLength = 2
                } else if (lead & 0xF0) == 0xE0 {
                    expectedLength = 3
                } else if (lead & 0xF8) == 0xF0 {
                    expectedLength = 4
                } else {
                    expectedLength = 1
                }
                let actualLength = raw.count - leadIndex
                if expectedLength > actualLength {
                    decodableCount = leadIndex
                }
            }
        }
        let decodable = Data(raw.prefix(decodableCount))
        outputDataBuffer = Data(raw.dropFirst(decodableCount))
        outputBuffer += String(decoding: decodable, as: UTF8.self)

        // OpenSSH's password prompt is intentionally not newline terminated.
        // Detect it in the partial buffer so a queued password is written only
        // after the PTY has switched to the password reader with echo off.
        observeSSHPasswordPrompt(in: outputBuffer)
        submitQueuedSSHPasswordIfPromptVisible()
        // Swift treats CRLF as one extended grapheme Character, so
        // `String.firstIndex(of: "\n")` never finds the LF emitted by a PTY.
        // Scan Unicode scalars instead; otherwise every CLI line remained in
        // the buffer and the prompt broker appeared permanently stuck.
        while let newline = outputBuffer.unicodeScalars.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newline]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let afterNewline = outputBuffer.unicodeScalars.index(after: newline)
            outputBuffer = String(outputBuffer[afterNewline...])
            consumeLine(line)
            // The announcement and OpenSSH's non-newline `password:` prompt
            // may arrive in the same read. Re-check after processing the line
            // that arms the pending-password state.
            submitQueuedSSHPasswordIfPromptVisible()
        }
    }

    /// Detect the real OpenSSH password prompt independently of line framing.
    ///
    /// The PTY can split `password:` across reads, or append a CR/LF before
    /// the GUI receives the chunk.  Looking only at the current partial
    /// buffer (or only at newline-delimited lines) therefore loses the prompt
    /// and leaves ssh waiting forever.  This helper is called for both paths
    /// while `awaitingSSHPassword` is armed, so it never treats unrelated
    /// output as a password request and never logs the secret itself.
    private func observeSSHPasswordPrompt(in text: String) {
        guard awaitingSSHPassword, !sshPasswordPromptVisible else { return }
        // OpenSSH normally prints `user@host's password:` (with no newline),
        // but a few builds use `password for user@host:`.  Match the prompt
        // suffix and an SSH-specific context after stripping terminal colour
        // sequences; a generic log line containing the word “password” must
        // never release a queued credential early.
        let ansiStripped = text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        for rawLine in ansiStripped.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lowercased = line.lowercased()
            let englishSuffix = lowercased.hasSuffix("password:")
            // Some OpenSSH/libssh builds phrase the prompt as
            // `password for user@host:`.  In that form the line ends in the
            // target's colon rather than `password:`, so treat it as a
            // separate, explicitly-targeted prompt shape.  Requiring the
            // target marker (or an SSH/OpenSSH label) keeps ordinary log
            // lines such as `password for account:` from releasing a queued
            // credential.
            let passwordForTarget = lowercased.contains("password for ")
                && (lowercased.contains("@")
                    || lowercased.contains("ssh")
                    || lowercased.contains("openssh"))
                && lowercased.hasSuffix(":")
            let englishContext = lowercased.contains("'s password:")
                || lowercased.contains("’s password:")
                || (lowercased.contains("@") && englishSuffix)
                || (lowercased.contains("ssh") && englishSuffix)
            // Keyboard-interactive PAM configurations often emit a bare
            // `Password:` prompt instead of OpenSSH's usual
            // `user@host's password:` form.  This is safe to accept here
            // because awaitingSSHPassword was armed only by the CLI's
            // explicit SSH-password hand-off announcement immediately
            // before launching the authentication exchange; ordinary log
            // lines cannot set that state.
            let bareInteractivePassword = awaitingSSHPassword
                && (lowercased == "password:" || lowercased == "password：")
            let englishPrompt = (englishSuffix && englishContext)
                || passwordForTarget
                || bareInteractivePassword
            let chineseSuffix = lowercased.hasSuffix("密码:") || lowercased.hasSuffix("密码：")
            let chineseContext = lowercased.contains("ssh")
                || lowercased.contains("openssh")
                || lowercased.contains("vps")
                || lowercased.contains("登录")
                || lowercased.contains("@")
            if englishPrompt || (chineseSuffix && chineseContext) {
                sshPasswordPromptVisible = true
                return
            }
        }
    }

    private func submitQueuedSSHPasswordIfPromptVisible() {
        // OpenSSH writes `password:` without a newline.  Keep the state armed
        // when the prompt is visible but the user has not entered a password
        // yet; a later submit from either masked field must be able to wake
        // this same exchange.  The old `!sshPasswordPromptVisible` guard made
        // that impossible and left the SSH child parked forever.
        guard awaitingSSHPassword else { return }
        if !sshPasswordPromptVisible {
            // The prompt is normally a non-newline PTY fragment.  Once it has
            // been observed, retain that fact independently of outputBuffer:
            // a following CR/LF can move the prompt into consumeLine and clear
            // the buffer before the user clicks Submit.
            observeSSHPasswordPrompt(in: outputBuffer)
            guard sshPasswordPromptVisible else {
                return
            }
        }
        // Never transmit the live SecureField draft implicitly.  A user may be
        // halfway through typing; sending that prefix creates a real failed
        // password attempt.  The draft is sent only after an explicit Enter or
        // the dedicated 提交密码 button queues it in queuedSSHPassword.
        let password = queuedSSHPassword
        guard let password, !password.isEmpty, operationRunning, let inputPipe else { return }
        operationLog += "[PNA] 已自动提交 SSH 密码（内容不记录）\n"
        // `Process.isRunning` can still be false for the forkpty relay during
        // the short interval in which its stdin is already valid.  The pipe
        // is the authoritative hand-off; gating on Process.isRunning drops
        // the answer and strands OpenSSH at its password prompt.
        writeInput(password, through: inputPipe)
    }

    private func flushOutputBuffer() {
        if !outputDataBuffer.isEmpty {
            outputBuffer += String(decoding: outputDataBuffer, as: UTF8.self)
            outputDataBuffer.removeAll(keepingCapacity: true)
            observeSSHPasswordPrompt(in: outputBuffer)
            submitQueuedSSHPasswordIfPromptVisible()
        }
        if !outputBuffer.isEmpty {
            consumeLine(outputBuffer.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")))
            outputBuffer = ""
        }
    }

    private func consumeLine(_ line: String) {
        // The prompt may have been terminated by CR/LF before this line is
        // delivered.  Observe it before handling framed or localized lines
        // so a queued password is not stranded by line parsing.
        observeSSHPasswordPrompt(in: line)
        if line.hasPrefix("PNA_GUI_PROMPT_B64=") {
            let prompt = decodeFrame(String(line.dropFirst("PNA_GUI_PROMPT_B64=".count)))
            handlePrompt(prompt, secret: false)
            return
        }
        if line.hasPrefix("PNA_GUI_SECRET_B64=") {
            let prompt = decodeFrame(String(line.dropFirst("PNA_GUI_SECRET_B64=".count)))
            handlePrompt(prompt, secret: true)
            return
        }
        // The Darwin CLI deliberately keeps the actual password prompt out
        // of the regular prompt protocol because OpenSSH owns the TTY. It
        // announces that hand-off as a normal log line instead. Promote that
        // announcement to the GUI secret prompt and consume the optional
        // password entered in the connection form. Without this bridge a
        // password typed before starting an operation was never sent to
        // OpenSSH, producing two retries followed by Permission denied even
        // when the credential was correct.
        let lowercasedLine = line.lowercased()
        // Host-key fingerprints are a normal, read-only checkpoint.  The
        // following managed-key verification intentionally emits no prompt,
        // so keep the status specific instead of showing “等待 CLI 提示…”
        // while OpenSSH performs its bounded probe.
        if lowercasedLine.contains("saved vps ssh host public-key fingerprint")
            || line.contains("已保存的 VPS SSH Host 公钥指纹") {
            operationStatus = "正在验证 SSH key…"
        }
        // Operation [2] deliberately keeps the SSH forwarding process alive
        // after the panel URL is ready.  Promote both the English and
        // localized status variants to native state so PromptPanel can expose
        // an explicit close button.  The URL is optional: some CLI builds
        // open it themselves and only print the keep-alive sentence.
        if selectedOperation?.id == "2" {
            let tunnelCloseAck = lowercasedLine.contains("tna_gui_tunnel_close_ack")
                || lowercasedLine.contains("pna_gui_tunnel_close_ack")
            if tunnelCloseAck {
                panelTunnelActive = false
                panelTunnelClosing = false
                panelLocalURL = nil
                operationStatus = "面板隧道已关闭"
            }
            let announcesTunnel = lowercasedLine.contains("panel ssh tunnel is active")
                || lowercasedLine.contains("panel ssh tunnel is being kept alive")
                || lowercasedLine.contains("panel_tunnel_session_active")
                || lowercasedLine.contains("close panel tunnel")
                || line.contains("面板 SSH 隧道")
                || line.contains("关闭面板隧道")
                || line.contains("面板隧道已")
            // A localized close acknowledgement may itself contain “面板隧道已…”.
            // Never let that acknowledgement immediately re-open the button.
            if announcesTunnel && !tunnelCloseAck {
                panelTunnelActive = true
                panelTunnelClosing = false
                operationStatus = "面板隧道已打开"
            }
            if !tunnelCloseAck,
               let urlStart = line.range(of: "http://") ?? line.range(of: "https://") {
                let tail = line[urlStart.lowerBound...]
                let candidate = tail.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                if let url = URL(string: candidate),
                   let scheme = url.scheme?.lowercased(),
                   (scheme == "http" || scheme == "https"),
                   (url.host?.lowercased() == "127.0.0.1" || url.host?.lowercased() == "localhost") {
                    panelLocalURL = candidate
                    panelTunnelActive = true
                }
            }
        }
        if operationRunning,
           line.contains("OpenSSH 即将请求 VPS 密码")
            || line.contains("图形遮罩密码框中输入")
            || lowercasedLine.contains("openssh is about to request the vps password")
            || lowercasedLine.contains("enter it in the graphical masked password dialog") {
            let prompt = "VPS 登录密码（当前 SSH 操作）"
            // Mark this normal log announcement as a secret prompt and queue
            // a pre-filled password. It is written only after the actual
            // OpenSSH `password:` prompt appears on the PTY, then cleared from
            // memory by writeInput just like the manual SecureField path.
            operationPrompt = prompt
            operationSecretPrompt = true
            awaitingSSHPassword = true
            sshPasswordPromptVisible = false
            if !passwordDraft.isEmpty {
                queuedSSHPassword = passwordDraft
                passwordDraft = ""
            }
        }
        if !line.isEmpty {
            operationLog += line + "\n"
            parseManagedKeyOutput(line)
            // `TEMPORARY_SSH_KEY_OK` is intentionally a prefix of the old
            // broad `SSH_KEY_OK` check.  It only confirms a one-use key for
            // this operation and must never mark the target as a durable
            // connection or persist it as the last managed node.  Accept
            // only explicit durable markers (including legacy localized
            // success lines) here.
            let marker = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let temporaryKeyMarker = marker.range(of: "TEMPORARY_SSH_KEY_OK", options: [.caseInsensitive]) != nil
            let durableKeyMarker = marker == "SSH_KEY_OK"
                || marker.hasPrefix("SSH_KEY_OK：已使用")
                || marker.hasPrefix("SSH_KEY_OK: the managed key")
                || marker == "SSH_PASS_OK"
                || marker.contains("已绑定为")
                || marker.contains("SSH 连接已建立")
                || marker.contains("SSH 已连接")
            if durableKeyMarker && !temporaryKeyMarker && selectedOperationUsesSSH {
                markConnected()
            }
        }
    }

    private func handlePrompt(_ prompt: String, secret: Bool) {
        operationPrompt = prompt
        operationSecretPrompt = secret
        let lowercasedPrompt = prompt.lowercased()
        if secret {
            // A password typed before starting an operation is consumed only
            // for an explicit SSH password prompt. This removes the old
            // requirement to wait for a hidden prompt while retaining the
            // manual SecureField fallback when the field was left empty.
            // Only a framed prompt that explicitly names the SSH hand-off may
            // consume the connection form's `passwordDraft`.  Other secret
            // prompts (for example, the *new* VPS password in operation [5],
            // panel credentials, API tokens, or a generic “password” label)
            // belong to that operation and must stay manual; sending the
            // current login password there silently writes the wrong secret.
            let hasPasswordTerm = lowercasedPrompt.contains("password") || prompt.contains("密码")
            let isSSHPasswordPrompt = hasPasswordTerm && (
                prompt.contains("SSH 密码")
                    || prompt.contains("当前 SSH 操作")
                    || lowercasedPrompt.contains("openssh")
                    || lowercasedPrompt.contains("ssh password")
                    || (lowercasedPrompt.contains("vps password")
                        && (lowercasedPrompt.contains("ssh") || lowercasedPrompt.contains("login")))
                    || (lowercasedPrompt.contains("vps login password")
                        && lowercasedPrompt.contains("ssh"))
            )
            if isSSHPasswordPrompt, !passwordDraft.isEmpty {
                let password = passwordDraft
                operationLog += "[PNA] 已自动提交 SSH 密码（内容不记录）\n"
                sendInput(password)
            }
            return
        }

        // The handoff has already been copied to the system pasteboard at
        // this point.  Keep this checkpoint visible so the operator can paste
        // the two VPS credential handoff blocks into a password manager before
        // choosing whether to clear them.  This branch intentionally runs
        // before automatic routing: a generic auto-answer here would erase
        // the clipboard before the user has a chance to paste it.
        if isClipboardClearPrompt(prompt) {
            operationStatus = "交接单已复制，等待确认"
            armClipboardClearTimeout()
            return
        }

        guard autoRoutingEnabled else { return }

        if selectedOperation?.id == "K",
           let choice = pendingKeyMenuChoice,
           // The Darwin CLI's framed K menu prompt is the short text
           // "选择操作" (the surrounding menu is emitted as regular
           // output), while older builds used "请选择". Accept both so
           // card actions such as 查看全部/解绑 do not stall at the menu.
           prompt.contains("选择操作") || prompt.contains("请选择") || prompt.contains("绑定 key 管理")
                || lowercasedPrompt.contains("choose action")
                || lowercasedPrompt.contains("key management") {
            pendingKeyMenuChoice = nil
            sendAutomaticInput(choice, note: "已自动打开 key 管理项 [" + choice + "]")
            return
        }

        if selectedOperation?.id == "K", choiceForUnbindTarget(in: prompt) != nil {
            let choice = choiceForUnbindTarget(in: prompt)!
            sendAutomaticInput(choice, note: "已自动选中当前目标解绑：" + user + "@" + host + ":" + port)
            return
        }

        if prompt.contains("SSH 登录方式") || prompt.contains("请选择登录方式") || prompt.contains("登录方式")
                || lowercasedPrompt.contains("login method")
                || lowercasedPrompt.contains("authentication method") {
            let answer = authMode == "节点长期 key" ? "2" : "1"
            sendAutomaticInput(answer, note: "已自动选择认证方式：" + authMode)
            return
        }

        // Use the explicit fields in this native form instead of selecting a
        // possibly stale history entry from the CLI's interactive picker.
        if prompt.contains("最近使用的 VPS") || prompt.contains("选择最近使用") || prompt.contains("选择历史编号")
                || lowercasedPrompt.contains("recent vps")
                || lowercasedPrompt.contains("recent target")
                || lowercasedPrompt.contains("history number") {
            sendAutomaticInput("M", note: "已自动使用当前连接字段")
            return
        }
        if prompt.contains("VPS IP") || prompt.contains("VPS 主机") || prompt.contains("VPS 地址")
                || lowercasedPrompt.contains("vps host")
                || lowercasedPrompt.contains("vps ip")
                || lowercasedPrompt.contains("hostname") {
            let candidateHost = autoTargetValues[safe: 0]
                ?? (selectedOperation?.id == "K" && !keyManagementTargetProvided ? "" : host)
            if selectedOperation?.id == "K",
               candidateHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A generic K entry has no target form: do not answer the
                // CLI's required host prompt with an empty line (or with the
                // last VPS left in the hidden form).  Keep the framed prompt
                // visible and switch the remainder of this mixed operation to
                // explicit input so the user can provide the right host,
                // account, and port one by one.
                autoRoutingEnabled = false
                operationStatus = "等待 VPS 地址"
                showToast("管理 key 的远程操作需要 VPS 地址；请在下方输入，不能留空")
                return
            }
            sendAutomaticInput(candidateHost, note: "已自动填入 VPS 地址")
            return
        }
        if prompt.contains("SSH 用户") || prompt.contains("SSH 用户名")
                || lowercasedPrompt.contains("ssh user")
                || lowercasedPrompt.contains("ssh username")
                || lowercasedPrompt.contains("username") {
            sendAutomaticInput(autoTargetValues[safe: 1] ?? user, note: "已自动填入 SSH 用户")
            return
        }
        if prompt.contains("SSH 端口") || lowercasedPrompt.contains("ssh port") {
            sendAutomaticInput(autoTargetValues[safe: 2] ?? port, note: "已自动填入 SSH 端口")
            return
        }

        // When long-key mode has no key for this host + user, the CLI first
        // verifies one password and then asks whether that verified key may
        // be bound to the target. The user chose long-key mode explicitly,
        // so confirm that binding in the GUI instead of leaving the workflow
        // parked at an unlabelled CLI prompt.
        // Only the post-password success confirmation is safe to answer
        // automatically.  A stale-key recovery prompt also contains “绑定”
        // but moving an old key is a destructive, user-visible choice and
        // must remain on screen for an explicit answer.
        let isInitialManagedKeyBindConfirmation =
            prompt.contains("密码登录已验证成功")
                || (lowercasedPrompt.contains("password authentication succeeded")
                    && lowercasedPrompt.contains("bind"))
        if authMode == "节点长期 key", isInitialManagedKeyBindConfirmation {
            sendAutomaticInput("y", note: "已确认绑定当前 VPS + SSH 用户的长期 key")
            return
        }

        // Secret handoff is deliberately log-safe in GUI mode.  The payload
        // is already in the system clipboard; acknowledge the save checkpoint
        // while leaving the clear decision to the visible prompt above.
        if prompt.contains("保存好以后按 Enter")
                || lowercasedPrompt.contains("after saving it, press enter") {
            sendAutomaticInput("", note: "已完成秘密交接保存确认")
            return
        }
    }

    /// Return true when the collected operation output contains a durable
    /// authentication success marker.  Parse line by line so a temporary-key
    /// marker cannot accidentally match the broad `SSH_KEY_OK` prefix.
    private func containsDurableSSHMarker(_ output: String) -> Bool {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let marker = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let temporary = marker.range(of: "TEMPORARY_SSH_KEY_OK", options: [.caseInsensitive]) != nil
            guard !temporary else { continue }
            if marker == "SSH_KEY_OK"
                || marker.hasPrefix("SSH_KEY_OK：已使用")
                || marker.hasPrefix("SSH_KEY_OK: the managed key")
                || marker == "SSH_PASS_OK"
                || marker.range(of: "key is now bound", options: [.caseInsensitive]) != nil
                || marker.contains("已绑定为")
                || marker.contains("已绑定 SSH 登录密钥")
                || marker.contains("SSH 连接已建立")
                || marker.contains("SSH 已连接") {
                return true
            }
        }
        return false
    }

    private func markConnected() {
        sshAuthenticatedForOperation = true
        let target = RecentTarget(host: host, user: user, port: port)
        activeTarget = target
        // Keep a bounded, de-duplicated non-secret history. Key bindings are
        // not stored here: the CLI keeps one managed key per host + user
        // scope, so several VPSs and users can coexist safely.
        recentTargets = [target] + recentTargets.filter {
            !($0.host == target.host && $0.user == target.user && $0.port == target.port)
        }
        if recentTargets.count > 12 {
            recentTargets = Array(recentTargets.prefix(12))
        }
        connectionState = "已连接"
        lastOperationTitle = selectedOperation?.title ?? "完整菜单"
        lastOperationAt = Date()
        let defaults = UserDefaults.standard
        defaults.set(target.host, forKey: "PNA.lastHost")
        defaults.set(target.user, forKey: "PNA.lastUser")
        defaults.set(target.port, forKey: "PNA.lastPort")
        defaults.set(connectionState, forKey: "PNA.connectionState")
        defaults.set(lastOperationTitle, forKey: "PNA.lastOperationTitle")
        defaults.set(lastOperationAt, forKey: "PNA.lastOperationAt")
        let history = recentTargets.map { ["host": $0.host, "user": $0.user, "port": $0.port] }
        if let data = try? JSONSerialization.data(withJSONObject: history) {
            defaults.set(data, forKey: "PNA.recentTargets")
        }
    }

    private func parseManagedKeyOutput(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("已绑定 key 总目录") {
            managedKeyEntries = []
            pendingManagedKeyIndex = nil
            parsingManagedKeyList = true
            return
        }
        // The CLI also prints recent-history rows such as
        // "[1] root@host:22 2026-09-03 12:00". They are not key entries.
        // Only parse bracketed rows after the explicit managed-key header.
        guard parsingManagedKeyList else { return }
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else {
            if trimmed.hasPrefix("私钥："), let index = pendingManagedKeyIndex {
                managedKeyEntries[index].privatePath = String(trimmed.dropFirst("私钥：".count)).trimmingCharacters(in: .whitespaces)
                persistManagedKeyEntries()
            } else if trimmed.hasPrefix("公钥："), let index = pendingManagedKeyIndex {
                managedKeyEntries[index].publicPath = String(trimmed.dropFirst("公钥：".count)).trimmingCharacters(in: .whitespaces)
                persistManagedKeyEntries()
            }
            return
        }
        let body = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        guard let at = body.firstIndex(of: "@") else { return }
        let userPart = String(body[..<at])
        let endpoint = String(body[body.index(after: at)...])
        guard let colon = endpoint.lastIndex(of: ":"), colon < endpoint.endIndex else { return }
        let hostPart = String(endpoint[..<colon])
        let portPart = String(endpoint[endpoint.index(after: colon)...])
        guard !userPart.isEmpty, !hostPart.isEmpty, !portPart.isEmpty else { return }
        managedKeyEntries.append(ManagedKeyEntry(host: hostPart, user: userPart, port: portPart))
        pendingManagedKeyIndex = managedKeyEntries.count - 1
        persistManagedKeyEntries()
    }

    private func persistManagedKeyEntries() {
        let values = managedKeyEntries.map { entry in
            [
                "host": entry.host,
                "user": entry.user,
                "port": entry.port,
                "privatePath": entry.privatePath,
                "publicPath": entry.publicPath
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: values) {
            UserDefaults.standard.set(data, forKey: "PNA.managedKeyEntries")
        }
    }

    private func choiceForUnbindTarget(in prompt: String) -> String? {
        let lowercasedPrompt = prompt.lowercased()
        guard prompt.contains("请输入要解绑的 VPS")
                || lowercasedPrompt.contains("enter the vps to unbind")
                || lowercasedPrompt.contains("target to unbind") else { return nil }
        let target = user + "@" + host + ":" + port
        for line in prompt.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard value.contains(target), let open = value.firstIndex(of: "["), let close = value.firstIndex(of: "]"), open < close else { continue }
            let number = String(value[value.index(after: open)..<close])
            if Int(number) != nil { return number }
        }
        return "M"
    }

    private func decodeFrame(_ encoded: String) -> String {
        guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8) else { return "等待输入" }
        return value
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
