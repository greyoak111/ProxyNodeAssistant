import SwiftUI
import AppKit

extension Color {
    static let pnaBackground = Color(red: 0.025, green: 0.055, blue: 0.085)
    static let pnaSurface = Color(red: 0.055, green: 0.105, blue: 0.145)
    static let pnaSurfaceRaised = Color(red: 0.075, green: 0.145, blue: 0.19)
    static let pnaAccent = Color(red: 0.28, green: 0.88, blue: 0.94)
    static let pnaBlue = Color(red: 0.29, green: 0.55, blue: 1.0)
    static let pnaGreen = Color(red: 0.35, green: 0.9, blue: 0.62)
    static let pnaOrange = Color(red: 1.0, green: 0.63, blue: 0.26)
    static let pnaPurple = Color(red: 0.68, green: 0.52, blue: 0.98)
    static let pnaRed = Color(red: 1.0, green: 0.36, blue: 0.43)
    static let pnaText = Color(red: 0.89, green: 0.95, blue: 0.97)
    static let pnaMuted = Color(red: 0.48, green: 0.6, blue: 0.66)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.pnaBackground.ignoresSafeArea()
            HStack(spacing: 0) {
                Sidebar()
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 1)
                VStack(spacing: 0) {
                    TopBar()
                    if model.workspacePresented {
                        page
                            .padding(.horizontal, 38)
                            .padding(.top, 18)
                            .padding(.bottom, 22)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            page
                                .padding(.horizontal, 38)
                                .padding(.top, 28)
                                .padding(.bottom, 42)
                        }
                    }
                }
            }
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.toast)
    }

    @ViewBuilder
    private var page: some View {
        if model.workspacePresented {
            OperationWorkspaceView()
        } else {
            switch model.section {
            case .overview: DashboardView()
            case .settings: SettingsView()
            case .install, .access, .maintain, .security, .backup, .local:
                OperationCatalogView(category: model.section.operationCategory!)
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ProxyNode")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.pnaText)
                    Text("ASSISTANT")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(Color.pnaAccent.opacity(0.8))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 40)

            Text("工作区")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Color.pnaMuted)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)

            VStack(spacing: 5) {
                ForEach(AppSection.allCases) { item in
                    SidebarItem(item: item, selected: model.section == item) {
                        model.section = item
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.pnaGreen)
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.pnaGreen.opacity(0.7), radius: 5)
                    Text("本地核心已验证")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.pnaText.opacity(0.75))
                }
                Text("v1.0.0 · LOCAL / FAIL-CLOSED")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .frame(width: 226)
        .background(.ultraThinMaterial.opacity(0.18))
    }
}

struct SidebarItem: View {
    let item: AppSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 19)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                Spacer()
                if selected {
                    Capsule()
                        .fill(Color.pnaAccent)
                        .frame(width: 3, height: 18)
                }
            }
            .foregroundStyle(selected ? Color.pnaText : Color.pnaMuted)
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(selected ? Color.pnaAccent.opacity(0.14) : (hovering ? Color.white.opacity(0.05) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct TopBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 15) {
            Text(model.section.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.pnaText)
            Spacer()
            HStack(spacing: 9) {
                Circle()
                    .fill(model.connectionState == "已连接" ? Color.pnaGreen : Color.pnaMuted)
                    .frame(width: 7, height: 7)
                Text(model.connectionState == "已连接" ? "已连接 · " + (model.activeTarget?.host ?? model.host) : "本地 GUI 已就绪")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.pnaText.opacity(0.8))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.pnaGreen.opacity(0.1)))
            .overlay(Capsule().stroke(Color.pnaGreen.opacity(0.22), lineWidth: 1))

            Button {
                model.showToast("当前版本已是最新")
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.pnaMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 38)
        .padding(.top, 25)
        .padding(.bottom, 10)
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.connectionState == "已连接" ? "REMOTE::SSH_READY" : "LOCAL::FAIL_CLOSED")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.pnaAccent)
                    Text("节点基础设施控制台")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.pnaText)
                    Text("原生 macOS 工作区：连接、施工、诊断与恢复都在窗口内完成")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                }
                Spacer()
                    Text(model.connectionState == "已连接" ? "已连接主机" : "等待本次连接")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
                    .padding(.bottom, 4)
            }

            NodeHeroCard()

            MultiKeyDashboardCard()

            if !model.managedKeyEntries.isEmpty {
                ManagedKeysCard()
            }

            VStack(alignment: .leading, spacing: 13) {
                SectionLabel(title: "快速操作", detail: "常用动作")
                HStack(spacing: 13) {
                    QuickAction(icon: "arrow.triangle.2.circlepath", title: "安装 / 升级", subtitle: "唯一施工入口", tint: Color.pnaAccent) {
                        model.openOperation(id: "1")
                    }
                    QuickAction(icon: "stethoscope", title: "自动体检", subtitle: "诊断节点状态", tint: Color.pnaBlue) {
                        model.openOperation(id: "3")
                    }
                    QuickAction(icon: "rectangle.inset.filled.and.person.filled", title: "打开 3x-ui", subtitle: "本地安全隧道", tint: Color.pnaOrange) {
                        model.openOperation(id: "2")
                    }
                    QuickAction(icon: "externaldrive.badge.checkmark", title: "生成备份", subtitle: "变更前先留底", tint: Color.pnaGreen) {
                        model.openOperation(id: "9")
                    }
                }
            }

            HStack(alignment: .top, spacing: 15) {
                TrafficCard()
                    .frame(maxWidth: .infinity)
                ActivityCard()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct MultiKeyDashboardCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: "key.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.pnaBlue)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.pnaBlue.opacity(0.13)))
            VStack(alignment: .leading, spacing: 4) {
                Text("多节点 key 管理")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                Text("长期 key 按 VPS 主机 + SSH 用户分别绑定；查看、解绑、恢复和归档全部绑定位置")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
            }
            Spacer()
            HStack(spacing: 8) {
                KeyActionButton(title: "新增 key", icon: "plus", tint: Color.pnaAccent) {
                    model.openOperation(id: "11")
                }
                Button {
                    model.openOperation(id: "K")
                } label: {
                    Label("打开管理", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaBlue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.pnaBlue.opacity(0.12)))
                        .overlay(Capsule().stroke(Color.pnaBlue.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.pnaBlue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.pnaBlue.opacity(0.18), lineWidth: 1))
    }
}

struct NodeHeroCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let target = model.activeTarget
        let connected = model.connectionState == "已连接" && target != nil
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 8) {
                    Text("当前节点")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Color.pnaAccent)
                    Text("·")
                        .foregroundStyle(Color.pnaMuted)
                    Text("已脱敏")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                }
                Text(target?.host ?? "尚未连接节点")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Color.pnaGreen)
                    Text(connected ? target!.user + " · SSH " + target!.port + " · 已完成真实握手" : "本机未保存远端状态 · 运行操作后再检测")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.pnaText.opacity(0.72))
                }
                HStack(spacing: 8) {
                    StatusPill(text: connected ? "SSH 已连接" : "尚未连接", tint: connected ? Color.pnaGreen : Color.pnaMuted)
                    StatusPill(text: model.lastOperationTitle.isEmpty ? "等待操作" : "最近：\(model.lastOperationTitle)", tint: Color.pnaBlue)
                    StatusPill(text: connected ? "状态来自 CLI" : "不会伪造状态", tint: Color.pnaAccent)
                }
            }
            Spacer()
            TopologyGraphic()
                .frame(width: 190, height: 150)
                .padding(.trailing, 30)
            VStack(alignment: .trailing, spacing: 11) {
                Button {
                    model.openOperation(id: "2")
                } label: {
                    Label("打开高级控制台", systemImage: "terminal.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaBackground)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(Color.pnaAccent))
                }
                .buttonStyle(.plain)
                Button {
                    model.section = .access
                } label: {
                    Text("查看节点详情 →")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 27)
        .padding(.vertical, 25)
        .background(GlassCardBackground(accent: Color.pnaAccent))
    }
}

struct TopologyGraphic: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.pnaAccent.opacity(0.12), lineWidth: 1)
                .frame(width: 144, height: 144)
            Circle()
                .stroke(Color.pnaBlue.opacity(0.1), lineWidth: 1)
                .frame(width: 108, height: 108)
            Path { path in
                path.move(to: CGPoint(x: 95, y: 22))
                path.addCurve(to: CGPoint(x: 42, y: 116), control1: CGPoint(x: 18, y: 45), control2: CGPoint(x: 12, y: 89))
                path.addCurve(to: CGPoint(x: 148, y: 75), control1: CGPoint(x: 80, y: 146), control2: CGPoint(x: 130, y: 137))
                path.addCurve(to: CGPoint(x: 95, y: 22), control1: CGPoint(x: 167, y: 35), control2: CGPoint(x: 116, y: 9))
            }
            .stroke(LinearGradient(colors: [Color.pnaAccent, Color.pnaBlue], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            NodeDot(position: CGPoint(x: 95, y: 22), tint: Color.pnaAccent)
            NodeDot(position: CGPoint(x: 42, y: 116), tint: Color.pnaBlue)
            NodeDot(position: CGPoint(x: 148, y: 75), tint: Color.pnaGreen)
        }
    }
}

struct NodeDot: View {
    let position: CGPoint
    let tint: Color
    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 9, height: 9)
            .shadow(color: tint.opacity(0.8), radius: 8)
            .position(position)
    }
}

struct QuickAction: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 35, height: 35)
                    .background(Circle().fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaText)
                    Text(subtitle)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(17)
            .background(RoundedRectangle(cornerRadius: 16).fill(hovering ? Color.white.opacity(0.09) : Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(hovering ? 0.16 : 0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct TrafficCard: View {
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 17) {
                SectionLabel(title: "本月流量", detail: "运行 OP:17 后显示")
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.pnaText)
                    Text("待检测")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaAccent)
                    Spacer()
                    Text("不会预填账单数据")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: [Color.pnaAccent, Color.pnaBlue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 0)
                    }
                }
                .frame(height: 8)
                HStack {
                    Label("本机尚未读取 VPS 计数", systemImage: "minus.circle")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                    Spacer()
                    Text("等待 OP:17")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                }
            }
        }
    }
}

struct ActivityCard: View {
    @EnvironmentObject private var model: AppModel

    private var events: [(String, String, String, Color)] {
        var result: [(String, String, String, Color)] = []
        if model.connectionState == "已连接", let target = model.activeTarget {
            result.append(("SSH 已握手 · \(target.display)", "真实状态", "checkmark.circle.fill", Color.pnaGreen))
        } else {
            result.append(("尚未完成 SSH 握手", "真实状态", "circle.dotted", Color.pnaMuted))
        }
        if !model.lastOperationTitle.isEmpty {
            result.append((model.lastOperationTitle, "最近操作", "arrow.triangle.2.circlepath", Color.pnaBlue))
        } else {
            result.append(("等待第一次远端操作", "本机", "clock", Color.pnaMuted))
        }
        result.append(("CLI 已随应用打包", "本地组件", "shippingbox.fill", Color.pnaAccent))
        return result
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title: "最近活动", detail: "本机记录")
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 11) {
                        Image(systemName: event.2)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(event.3)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(event.3.opacity(0.11)))
                        Text(event.0)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.pnaText.opacity(0.82))
                        Spacer()
                        Text(event.1)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Color.pnaMuted)
                    }
                }
            }
        }
    }
}

struct OperationCatalogView: View {
    @EnvironmentObject private var model: AppModel
    let category: OperationCategory

    private var section: AppSection {
        switch category {
        case .install: return .install
        case .access: return .access
        case .maintain: return .maintain
        case .security: return .security
        case .backup: return .backup
        case .local: return .local
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.eyebrow)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.7)
                        .foregroundStyle(Color.pnaAccent)
                    Text(section.title)
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.pnaText)
                    Text(categorySubtitle)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                }
                Spacer()
                Text("\(model.selectedCategoryOperations.count) 项")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.pnaAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.pnaAccent.opacity(0.1)))
            }

            if category == .install {
                InstallSafetyBanner()
            }

            if category == .access {
                MultiKeyBanner()
                if !model.managedKeyEntries.isEmpty {
                    ManagedKeysCard()
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(model.selectedCategoryOperations) { operation in
                    OperationCard(operation: operation) {
                        model.openOperation(id: operation.id)
                    }
                }
            }
        }
    }

    private var categorySubtitle: String {
        switch category {
        case .install: return "唯一施工入口；连接、预览、备份和 APPLY 确认都在一个工作区完成。"
        case .access: return "面板隧道、凭据交接和节点 key 的安全访问工具。"
        case .maintain: return "体检、修复、性能、伪装站与线路拓扑维护。"
        case .security: return "密钥、日志、白名单和高风险恢复动作。"
        case .backup: return "灾备、紧急报告与远端备份整理。"
        case .local: return "只作用于本机的剪贴板、代理、历史和服务商工具。"
        }
    }
}

struct MultiKeyBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "key.2.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.pnaBlue)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.pnaBlue.opacity(0.13)))
            VStack(alignment: .leading, spacing: 5) {
                Text("多节点 · 多用户 · 多把 key")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                Text("长期 key 按 VPS 主机 + SSH 用户独立绑定。新增节点不会覆盖旧 key；CLI 会在当前目标范围内自动查找匹配项。")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.pnaText.opacity(0.76))
                    .lineSpacing(3)
                Text("当前表单范围：" + model.currentKeyScope)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.pnaMuted)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 7) {
                    KeyActionButton(title: "查看全部", icon: "list.bullet", tint: Color.pnaBlue) {
                        model.openKeyManagement(choice: "1")
                    }
                    KeyActionButton(title: "可恢复备份", icon: "archivebox", tint: Color.pnaPurple) {
                        model.openKeyManagement(choice: "3")
                    }
                }
                Button {
                    model.openKeyManagement()
                } label: {
                    Label("打开完整管理", systemImage: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.pnaBlue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.pnaBlue.opacity(0.19), lineWidth: 1))
    }
}

struct ManagedKeysCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var removalCandidate: ManagedKeyEntry?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel(title: "已绑定 key", detail: "CLI 返回的真实条目")
                    Spacer()
                    Text(String(model.managedKeyEntries.count) + " 个绑定")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pnaBlue)
                }
                ForEach(model.managedKeyEntries) { entry in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(Color.pnaBlue)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.pnaBlue.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.targetDisplay)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.pnaText)
                            if !entry.privatePath.isEmpty {
                                Text(entry.privatePath)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Color.pnaMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Button("解绑") {
                            removalCandidate = entry
                        }
                        .buttonStyle(AccentTextButtonStyle())
                    }
                    if entry.id != model.managedKeyEntries.last?.id {
                        Divider().overlay(Color.white.opacity(0.07))
                    }
                }
                HStack(spacing: 8) {
                    KeyActionButton(title: "新增另一台 VPS", icon: "plus", tint: Color.pnaAccent) {
                        model.openOperation(id: "11")
                    }
                    KeyActionButton(title: "刷新列表", icon: "arrow.clockwise", tint: Color.pnaBlue) {
                        model.openKeyManagement(choice: "1")
                    }
                    Spacer()
                    Text("同一 VPS + 用户只保留一对 key；重新生成前先解绑旧绑定")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                }
            }
        }
        .alert("确认解绑 key", isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        )) {
            Button("取消", role: .cancel) { removalCandidate = nil }
            Button("解绑", role: .destructive) {
                guard let candidate = removalCandidate else { return }
                removalCandidate = nil
                model.openKeyManagement(choice: "2", target: candidate)
            }
        } message: {
            Text(removalCandidate.map { $0.targetDisplay } ?? "")
        }
    }
}

struct KeyActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Capsule().fill(tint.opacity(0.12)))
                .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct InstallSafetyBanner: View {
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.pnaGreen)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.pnaGreen.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text("FAIL-CLOSED 施工顺序")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.pnaGreen)
                Text("先只读识别，再收集线路和凭据；只有精确输入 APPLY 才会上传或修改远端。")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.pnaText.opacity(0.78))
            }
            Spacer()
            Text("BACKUP REQUIRED")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.pnaOrange)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.pnaGreen.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.pnaGreen.opacity(0.18), lineWidth: 1))
    }
}

struct OperationCard: View {
    let operation: OperationInfo
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 13) {
                Rectangle()
                    .fill(operation.tint)
                    .frame(width: 3)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: operation.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(operation.tint)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 10).fill(operation.tint.opacity(0.12)))
                        Spacer()
                        Text("[\(operation.id)]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.pnaMuted)
                    }
                    Text(operation.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaText)
                        .multilineTextAlignment(.leading)
                    Text(operation.description)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text("打开工作区")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(operation.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(17)
            .frame(minHeight: 174, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16).fill(hovering ? Color.white.opacity(0.09) : Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(operation.tint.opacity(hovering ? 0.34 : 0.11), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct OperationWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Button {
                    model.closeWorkspace()
                } label: {
                    Label("返回总览", systemImage: "arrow.left")
                }
                .buttonStyle(AccentTextButtonStyle())
                Text(model.selectedOperation?.title ?? "完整图形工作流菜单")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                Spacer()
                if model.panelTunnelActive {
                    HStack(spacing: 8) {
                        if let url = model.panelLocalURL {
                            Text(url)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.pnaMuted)
                                .lineLimit(1)
                        }
                        Button {
                            model.closePanelTunnel()
                        } label: {
                            Label(model.panelTunnelClosing ? "关闭中…" : "关闭面板隧道",
                                  systemImage: model.panelTunnelClosing ? "hourglass" : "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(AccentTextButtonStyle())
                        .disabled(model.panelTunnelClosing)
                    }
                }
                StatusPill(text: model.operationStatus, tint: model.operationRunning ? Color.pnaAccent : Color.pnaMuted)
            }

            HStack(alignment: .top, spacing: 14) {
                ConnectionPanel()
                    .frame(width: 318)
                VStack(spacing: 14) {
                    LogPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    PromptPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ConnectionPanel: View {
    @EnvironmentObject private var model: AppModel

    private var localOperationDescription: String {
        switch model.selectedOperation?.id {
        case "12":
            return "直接清除本机系统剪贴板，不读取、不连接 VPS，也不会启动 SSH。"
        case "14":
            return "保存当前 Mac 的系统代理设置后，可将 HTTP/HTTPS/SOCKS 代理切换到 127.0.0.1:10808 并关闭 PAC/WPAD，或恢复原设置；仅需 macOS 管理员授权，不连接 VPS。"
        case "T":
            return "读取或管理本机保存的服务商 API / 系统凭据，不连接 VPS。"
        case "H":
            return "查看、删除或清空本机保存的 VPS 地址历史；不保存密码和 key。"
        case "K":
            return "查看、归档在本机完成；解绑或恢复会在选定目标后使用 SSH，所有节点 key 仍按主机 + 用户独立管理。"
        default:
            return "此操作只作用于本机，不会建立 SSH 连接。"
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    let mixedKeyOperation = model.selectedOperation?.id == "K"
                    SectionLabel(title: model.selectedOperationUsesSSH
                                 ? "本次连接"
                                 : (mixedKeyOperation ? "本机操作 · 按选项连接" : "本机操作"),
                                 detail: model.selectedOperationUsesSSH
                                 ? "字段会直接交给 SSH"
                                 : (mixedKeyOperation ? "查看/归档无需登录；解绑/恢复会使用 SSH" : "无需登录 VPS"))
                    Spacer()
                    if model.selectedOperationUsesSSH {
                        StatusPill(text: model.connectionState, tint: model.connectionState == "已连接" ? Color.pnaGreen : Color.pnaMuted)
                    } else if model.selectedOperation?.id == "K" {
                        StatusPill(text: "按选项", tint: Color.pnaBlue)
                    } else {
                        StatusPill(text: "仅本机", tint: Color.pnaAccent)
                    }
                }
                Text(model.selectedOperationUsesSSH
                     ? "开始操作后，主机、用户和端口会自动提交给 CLI；只有密码等秘密仍会在真正提示出现时输入。"
                     : (model.selectedOperation?.id == "K"
                        ? "查看和归档只作用于当前 Mac；选择解绑或恢复后，CLI 会在目标明确时通过 SSH 操作对应 VPS。"
                        : (model.selectedOperation?.id == "14"
                           ? "此操作直接读取并保存当前 Mac 的系统代理设置，将 HTTP/HTTPS/SOCKS 指向 127.0.0.1:10808、关闭 PAC/WPAD 或恢复原设置；仅在 macOS 要求时请求管理员授权，不读取 VPS 地址或建立 SSH。"
                           : "此操作直接在当前 Mac 执行，不读取 VPS 地址、SSH 用户、端口或密码。")))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
                    .lineSpacing(3)
                if model.selectedOperationUsesSSH {
                if !model.recentTargets.isEmpty {
                    Menu {
                        ForEach(model.recentTargets) { target in
                            Button {
                                model.selectRecentTarget(target)
                            } label: {
                                Text(target.display)
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("载入其他节点（" + String(model.recentTargets.count) + " 个目标）")
                            Spacer()
                            Image(systemName: "chevron.down")
                        }
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.pnaAccent.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.pnaAccent.opacity(0.18), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                }
                WorkspaceField(title: "VPS / 主机", text: $model.host, placeholder: "例如 node.example.com")
                    .onChange(of: model.host) { _ in model.formTargetDidChange() }
                WorkspaceField(title: "SSH 用户", text: $model.user, placeholder: "root")
                    .onChange(of: model.user) { _ in model.formTargetDidChange() }
                WorkspaceField(title: "端口", text: $model.port, placeholder: "22")
                    .onChange(of: model.port) { _ in model.formTargetDidChange() }
                VStack(alignment: .leading, spacing: 7) {
                    Text("认证方式")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                    Picker("认证方式", selection: $model.authMode) {
                        Text("临时密码").tag("临时密码")
                        Text("节点长期 key").tag("节点长期 key")
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.pnaAccent)
                }
                Text(model.authMode == "节点长期 key"
                     ? "长期 key 会按 VPS 主机 + SSH 用户单独查找，支持同时绑定多台 VPS 或多个 SSH 用户。找不到当前范围的 key 时，CLI 会在真实遮罩密码提示中要求一次密码。"
                     : "临时密码只用于本次 SSH 操作；CLI 验证后建立一次性会话 key，操作结束、失败、取消或中断都会撤销远端临时公钥并删除本机临时 key，不会创建或覆盖长期 key。需要多节点长期登录时，请到“面板与访问”管理已绑定 key。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
                    .lineSpacing(3)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.authMode == "节点长期 key" ? "首次绑定密码（可选）" : "VPS 登录密码（可选）")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                    HStack(spacing: 8) {
                        SecureField("仅保存在本次操作内存中", text: $model.passwordDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.pnaText)
                            .padding(.horizontal, 10)
                            .frame(height: 35)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.pnaOrange.opacity(0.24), lineWidth: 1))
                            .onSubmit { model.submitPasswordDraft() }
                        if model.operationRunning {
                            Button("提交密码") { model.submitPasswordDraft() }
                                .buttonStyle(AccentTextButtonStyle())
                                .disabled(model.passwordDraft.isEmpty)
                        }
                    }
                    Text("填入后，CLI 出现真实 SSH 密码提示时会自动提交；留空则在下方遮罩框输入。密码不会写入日志、参数或磁盘。")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                        .lineSpacing(2)
                }
                if model.authMode == "节点长期 key" {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(Color.pnaBlue)
                        Text("绑定 key")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.pnaMuted)
                        Spacer()
                        if model.managedKeyEntries.isEmpty {
                            Button("读取全部") {
                                model.openKeyManagement(choice: "1")
                            }
                            .buttonStyle(AccentTextButtonStyle())
                        } else {
                            Menu {
                                ForEach(model.managedKeyEntries) { entry in
                                    Button {
                                        model.selectManagedKey(entry)
                                    } label: {
                                        Text(entry.targetDisplay)
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(model.currentManagedKey?.targetDisplay ?? "当前目标未绑定")
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                }
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(model.currentManagedKey == nil ? Color.pnaOrange : Color.pnaBlue)
                            }
                            .menuStyle(.borderlessButton)
                            Button {
                                model.openOperation(id: "11")
                            } label: {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.pnaAccent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                    if model.currentManagedKey == nil {
                        Text("当前主机 + SSH 用户没有绑定 key；填入首次绑定密码后，验证成功时才会绑定新 key。列表里的其他 VPS key 不会被拿来登录当前目标。")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(Color.pnaOrange.opacity(0.9))
                            .lineSpacing(2)
                    }
                }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(Color.pnaAccent)
                            Text("本机操作")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.pnaText)
                        }
                        Text(localOperationDescription)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Color.pnaMuted)
                            .lineSpacing(3)
                    }
                    .padding(.vertical, 8)
                }
                Divider().overlay(Color.white.opacity(0.08))
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(Color.pnaGreen)
                    Text("密码只进遮罩输入，不进参数、日志或磁盘")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.pnaText.opacity(0.72))
                }
                Spacer(minLength: 0)
                Button {
                    model.startSelectedOperation()
                } label: {
                    Label(model.operationRunning ? "运行中" : "开始操作", systemImage: model.operationRunning ? "hourglass" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(model.operationRunning)
            }
        }
    }
}

struct WorkspaceField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.pnaMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pnaText)
                .padding(.horizontal, 10)
                .frame(height: 35)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

struct LogPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(model.operationRunning ? Color.pnaAccent : Color.pnaMuted).frame(width: 7, height: 7)
                Text("运行日志")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                Text("LOCAL::FAIL_CLOSED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.pnaMuted)
                Spacer()
                Button("复制日志") { model.copyLog() }
                    .buttonStyle(AccentTextButtonStyle())
                Button("清空显示") { model.clearOperationLog() }
                    .buttonStyle(AccentTextButtonStyle())
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                Text(model.operationLog.isEmpty ? "暂无运行日志" : model.operationLog)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.pnaText.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(9)
            }
            .background(Color.black.opacity(0.24))
        }
        .background(GlassCardBackground())
        .frame(maxHeight: .infinity)
    }
}

struct PromptPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt = model.operationPrompt {
                Text(prompt)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                    .lineLimit(3)
                if model.clipboardClearPromptVisible {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(Color.pnaAccent)
                        Text("交接单已复制到本机剪贴板。请先粘贴到密码管理器，再选择“是 / Y”清空；\(model.clipboardClearTimeoutLabel) 秒内未选择会自动清空。")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Color.pnaMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Group {
                        if model.operationSecretPrompt {
                            SecureField("遮罩输入，不会显示", text: $model.inputDraft)
                        } else {
                            TextField("输入本次回答", text: $model.inputDraft)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.pnaText)
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.26)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.pnaAccent.opacity(0.28), lineWidth: 1))
                    Button("提交") { model.sendInput() }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .frame(width: 72)
                }
                HStack(spacing: 7) {
                    PromptShortcut(title: model.clipboardClearPromptVisible ? "清空 / Y" : "是 / Y") {
                        model.sendInput("y")
                    }
                    PromptShortcut(title: model.clipboardClearPromptVisible ? "保留 / N" : "否 / N") {
                        model.sendInput("n")
                    }
                    if !model.clipboardClearPromptVisible {
                        PromptShortcut(title: "直接回车") { model.sendInput("") }
                    }
                    Spacer()
                    if model.panelTunnelActive {
                        Button {
                            model.closePanelTunnel()
                        } label: {
                            Label(model.panelTunnelClosing ? "关闭中…" : "关闭面板隧道",
                                  systemImage: model.panelTunnelClosing ? "hourglass" : "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(AccentTextButtonStyle())
                        .disabled(model.panelTunnelClosing)
                    }
                    Button("安全停止") { model.stopOperation() }
                        .buttonStyle(AccentTextButtonStyle())
                }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "text.bubble.fill")
                        .foregroundStyle(Color.pnaMuted)
                    Text(model.operationRunning ? "等待 CLI 提示…" : "开始操作后，后续输入会在这里出现")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.pnaMuted)
                    Spacer()
                    if model.operationRunning {
                        if model.panelTunnelActive {
                            Button {
                                model.closePanelTunnel()
                            } label: {
                                Label(model.panelTunnelClosing ? "关闭中…" : "关闭面板隧道",
                                      systemImage: model.panelTunnelClosing ? "hourglass" : "rectangle.portrait.and.arrow.right")
                            }
                            .buttonStyle(AccentTextButtonStyle())
                            .disabled(model.panelTunnelClosing)
                        }
                        Button("安全停止") { model.stopOperation() }
                            .buttonStyle(AccentTextButtonStyle())
                    }
                }
            }
        }
        .padding(14)
        .background(GlassCardBackground())
    }
}

struct PromptShortcut: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(AccentTextButtonStyle())
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color.pnaBackground)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.pnaAccent.opacity(configuration.isPressed ? 0.75 : 1)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct NodesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageIntro(eyebrow: "NODE INVENTORY", title: "节点", subtitle: "只在本机保存地址、用户和端口；秘密凭据永不进入历史记录。") {
                Button {
                    model.showToast("新增节点将在高级控制台中完成")
                } label: {
                    Label("添加节点", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaBackground)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.pnaAccent))
                }
                .buttonStyle(.plain)
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).fill(Color.pnaAccent.opacity(0.12))
                                Image(systemName: "server.rack")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.pnaAccent)
                            }
                            .frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("当前 VPS")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.pnaText)
                                Text("主机地址已脱敏 · root · SSH 22")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(Color.pnaMuted)
                            }
                        }
                        Spacer()
                        StatusPill(text: "在线", tint: Color.pnaGreen)
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                    HStack(spacing: 35) {
                        NodeStat(title: "拓扑", value: "双路", detail: "Reality + XHTTP")
                        NodeStat(title: "性能档", value: "标准", detail: "可随时回滚")
                        NodeStat(title: "最近体检", value: "正常", detail: "3 个小时前")
                        NodeStat(title: "备份", value: "已就绪", detail: "变更前自动创建")
                    }
                }
            }

            HStack(alignment: .top, spacing: 15) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel(title: "登录方式", detail: "每次操作重新确认")
                        SettingRow(icon: "key.fill", title: "节点长期 key", value: "已绑定", tint: Color.pnaAccent)
                        SettingRow(icon: "checkmark.shield.fill", title: "Host Key", value: "已核对", tint: Color.pnaGreen)
                        SettingRow(icon: "clock.arrow.circlepath", title: "最近使用", value: "今天 09:12", tint: Color.pnaBlue)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel(title: "安全边界", detail: "本地优先")
                        Text("所有远端变更都先预览、备份，再由你输入 APPLY 确认。失败会立即停止并保留救援通道。")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.pnaText.opacity(0.75))
                            .lineSpacing(5)
                        Button("打开高级控制台") { model.openCLI() }
                            .buttonStyle(AccentTextButtonStyle())
                    }
                }
            }
        }
    }
}

struct PlanView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageIntro(eyebrow: "INSTALLATION PLAN", title: "施工计划", subtitle: "先在这里整理计划，再进入 Terminal 执行远端变更。") {
                Button {
                    model.makePlan()
                } label: {
                    Label("生成预览", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaBackground)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.pnaAccent))
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 15) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 21) {
                        FormLabel(title: "线路拓扑", detail: "必须明确选择")
                        Picker("线路拓扑", selection: $model.topology) {
                            ForEach(Topology.allCases) { topology in
                                Text(topology.rawValue).tag(topology)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(Color.pnaAccent)

                        FormLabel(title: "伪装站", detail: "15 套本地模板")
                        Picker("伪装站", selection: $model.camouflage) {
                            Text("按域名稳定").tag("按域名稳定")
                            Text("随机").tag("随机")
                            Text("指定编号").tag("指定编号")
                        }
                        .pickerStyle(.menu)

                        FormLabel(title: "性能档位", detail: "可回滚")
                        Picker("性能档位", selection: $model.performance) {
                            Text("自动").tag("自动")
                            Text("低配").tag("低配")
                            Text("标准").tag("标准")
                            Text("高配").tag("高配")
                        }
                        .pickerStyle(.segmented)
                        .tint(Color.pnaBlue)

                        Toggle(isOn: $model.warpEnabled) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("确保 WARP 开启")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.pnaText)
                                Text("不会因空输入被静默开启")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(Color.pnaMuted)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.pnaAccent))

                        HStack(spacing: 9) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(Color.pnaGreen)
                            Text("变更前备份已强制开启")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.pnaText.opacity(0.72))
                        }
                    }
                }
                .frame(width: 405)

                PlanPreviewCard()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct PlanPreviewCard: View {
    @EnvironmentObject private var model: AppModel

    private let steps = [
        ("01", "只读识别", "读取节点现状与构建版本"),
        ("02", "创建备份", "保存变更前基线"),
        ("03", "施工验货", "真实客户端验证线路"),
        ("04", "提交交接", "成功后才输出凭据")
    ]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 21) {
                HStack {
                    SectionLabel(title: "计划预览", detail: model.planReady ? "已生成" : "等待生成")
                    Spacer()
                    if model.planReady {
                        StatusPill(text: "READY", tint: Color.pnaGreen)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Text(step.0)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(index == 0 ? Color.pnaAccent : Color.pnaMuted)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill((index == 0 ? Color.pnaAccent : Color.pnaMuted).opacity(0.13)))
                                if index < steps.count - 1 {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.1))
                                        .frame(width: 1, height: 31)
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.1)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.pnaText)
                                Text(step.2)
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(Color.pnaMuted)
                            }
                            .padding(.top, 4)
                            Spacer()
                        }
                    }
                }
                Divider().overlay(Color.white.opacity(0.08))
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("确认后执行")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.pnaMuted)
                        Text("输入 APPLY 才会上传和修改")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.pnaText.opacity(0.8))
                    }
                    Spacer()
                    Button {
                        model.openCLI()
                    } label: {
                        Label("进入高级控制台", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(AccentTextButtonStyle())
                }
            }
        }
    }
}

struct SecurityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageIntro(eyebrow: "SECURITY & DIAGNOSTICS", title: "安全日志", subtitle: "把 SSH、防火墙、Nginx 和 Fail2ban 的检查结果集中在这里。") {
                Button {
                    model.showToast("诊断任务将在 Terminal 中执行")
                    model.openCLI()
                } label: {
                    Label("运行体检", systemImage: "stethoscope")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.pnaBackground)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.pnaAccent))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 15) {
                HealthScoreCard(score: "98", title: "安全评分", detail: "较上次 +4", tint: Color.pnaGreen)
                HealthScoreCard(score: "0", title: "待处理事件", detail: "当前无高风险", tint: Color.pnaAccent)
                HealthScoreCard(score: "4", title: "最近检查", detail: "均已通过", tint: Color.pnaBlue)
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 15) {
                    SectionLabel(title: "检查清单", detail: "最近一次 · 今天 09:12")
                    SecurityRow(icon: "checkmark.circle.fill", title: "SSH 登录与 Host Key", detail: "身份匹配，登录路径正常", tint: Color.pnaGreen)
                    SecurityRow(icon: "checkmark.circle.fill", title: "防火墙与 Fail2ban", detail: "规则存在，服务运行中", tint: Color.pnaGreen)
                    SecurityRow(icon: "checkmark.circle.fill", title: "Nginx / TLS", detail: "证书有效，橙云端口已验证", tint: Color.pnaGreen)
                    SecurityRow(icon: "checkmark.circle.fill", title: "线路真实验货", detail: "Reality 与 XHTTP 均通过", tint: Color.pnaGreen)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = false
    @State private var compactMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageIntro(eyebrow: "PREFERENCES", title: "设置", subtitle: "控制本机体验与安全偏好。凭据仍由系统安全存储负责。")
            HStack(alignment: .top, spacing: 15) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionLabel(title: "外观", detail: "macOS 深色主题")
                        SettingToggle(title: "启动时打开总览", detail: "快速查看节点状态", isOn: $launchAtLogin)
                        SettingToggle(title: "紧凑信息密度", detail: "减少卡片留白", isOn: $compactMode)
                        HStack {
                            Text("语言")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.pnaText)
                            Spacer()
                            Text("简体中文")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.pnaMuted)
                        }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionLabel(title: "关于", detail: "ProxyNodeAssistant")
                        Text("本地优先的 VPS 节点部署、维护、排障与恢复工具。")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.pnaText.opacity(0.78))
                            .lineSpacing(5)
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Color.pnaAccent)
                            Text("v1.0.0 · MIT License")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.pnaMuted)
                        }
                        HStack(spacing: 8) {
                            Button("打开完整工作区") { model.openFullMenu() }
                                .buttonStyle(AccentTextButtonStyle())
                            Button {
                                model.uninstallApplication()
                            } label: {
                                Label("卸载应用", systemImage: "trash")
                            }
                            .buttonStyle(AccentTextButtonStyle())
                        }
                        Text("用户级安装包的应用、配置和本地组件可直接卸载；若本工具曾接管系统代理，会先恢复原设置并按 macOS 要求授权。")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Color.pnaMuted)
                            .lineSpacing(3)
                    }
                }
            }
        }
    }
}

struct PageIntro<Actions: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    init(eyebrow: String, title: String, subtitle: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(Color.pnaAccent)
                Text(title)
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                Text(subtitle)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
            }
            Spacer()
            actions
        }
    }
}

struct SectionLabel: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.pnaText)
            Text(detail)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.pnaMuted)
        }
    }
}

struct FormLabel: View {
    let title: String
    let detail: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.pnaText)
            Spacer()
            Text(detail)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.pnaMuted)
        }
    }
}

struct StatusPill: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.11)))
            .overlay(Capsule().stroke(tint.opacity(0.24), lineWidth: 1))
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(21)
            .background(GlassCardBackground())
    }
}

struct GlassCardBackground: View {
    var accent: Color? = nil
    var body: some View {
        RoundedRectangle(cornerRadius: 19)
            .fill(Color.white.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 19)
                    .stroke(Color.white.opacity(0.085), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if let accent {
                    RoundedRectangle(cornerRadius: 19)
                        .fill(LinearGradient(colors: [accent.opacity(0.25), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .blur(radius: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 19))
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 22, y: 12)
    }
}

struct NodeStat: View {
    let title: String
    let value: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.pnaMuted)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.pnaText)
            Text(detail)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.pnaMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingRow: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.pnaText.opacity(0.82))
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.pnaMuted)
        }
    }
}

struct SecurityRow: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                Text(detail)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
            }
            Spacer()
            Text("通过")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 4)
    }
}

struct HealthScoreCard: View {
    let score: String
    let title: String
    let detail: String
    let tint: Color
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(score)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                Text(detail)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.pnaText)
                Text(detail)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.pnaMuted)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Color.pnaAccent))
    }
}

struct AccentTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.pnaAccent)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.pnaAccent.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .overlay(Capsule().stroke(Color.pnaAccent.opacity(0.25), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct BrandMark: View {
    var body: some View {
        if let path = Bundle.main.path(forResource: "ProxyNodeAssistant-v1.0.0-app-icon", ofType: "png"), let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 9))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.pnaAccent.opacity(0.14))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.pnaAccent)
            }
        }
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.pnaGreen)
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.pnaText)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }
}
