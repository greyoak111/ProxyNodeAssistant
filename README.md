<p align="center">
  <img src="gui/TextNodeAssistant-v0.9.5-app-icon.png" width="112" alt="TextNodeAssistant icon">
</p>

<h1 align="center">TextNodeAssistant v0.9.5</h1>

<p align="center">Windows / Android 双层私人网盘与 VPS 图形运维客户端</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.9.5-16d9e3?style=flat-square" alt="version 0.9.5">
  <img src="https://img.shields.io/badge/Windows-x64%20%7C%20x86%20%7C%20ARM64-16d9e3?style=flat-square" alt="Windows">
  <img src="https://img.shields.io/badge/Android-native%20Compose-16d9e3?style=flat-square" alt="Android">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4ee0b5?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <a href="TextNodeAssistant-v0.9.5-从零部署教程.md">从零部署教程</a> ·
  <a href="TextNodeAssistant-v0.9.5-完整使用说明书.md">完整使用说明书</a> ·
  <a href="ANDROID.md">Android 手册</a> ·
  <a href="BUILD.md">构建说明</a> ·
  <a href="TextNodeAssistant-v0.9.5-最终施工设计基线.md">设计与验收基线</a>
</p>

---

TextNodeAssistant（TNA）把私人网盘日常界面与完整 VPS 运维控制台放在同一个原生客户端中。外层用于文件、账号和节点切换；内层保留全部图形施工、诊断、备份、设备准入和恢复能力。Windows 版是单文件 WPF EXE，Android 版是 Kotlin + Jetpack Compose 原生 APK；两端使用同一套 `text-node-assistant v0.9.5` Linux 工具包。

项目坚持：

- **唯一施工入口**：只有高级控制台 `[1]` 可以上传、安装、升级、恢复缺失组件或改变灰云/橙云/双路拓扑；
- **失败即停**：退出码、结构化结束标记、真实探针和回读必须同时通过，失败后不复制空交接单、不猜端口、不继续开面板；
- **隐私优先**：公开源码和产物不内置真实 VPS、域名、邮箱、密码、Token、私钥、订阅或交接单；
- **可恢复**：施工前记录基线，危险动作先生成救援包；能安装、检测、回滚、拆除，并保留厂商 Console/VNC 兜底。

> 仅用于你拥有或得到明确授权的服务器。请遵守服务商条款、所在地法律和网络服务规则。

## 产品结构

```text
启动 TNA
  └─ 外层登录
      ├─ 普通网盘账号 → 自己的空间、传输、挂载
      └─ 本机 admin → admin 空间
             └─ 再验证 admin（默认开启）
                    └─ 完整高级图形运维控制台
```

- 本机 `admin` 密码只在本机验证，不会发送给 VPS、SSH、3x-ui 或 copyparty。
- 首次创建 admin 时同时写入系统保护凭据，并生成加密恢复包与恢复码；修改 admin 只能在内层执行。
- 普通网盘账号在外层注册，每台 VPS 最多 2 个；注册只在远端完整施工且当前设备受信后开放。
- 普通账号是节点/空间级账号，可在该 VPS 的所有受信设备上登录同一空间。
- 切换网盘 VPS 会退回登录页，必须输入目标 VPS 的网盘账密，避免跨节点串号。
- 新机或未绑定 VPS 时，外层如实显示“未挂载节点”，并引导进入高级控制台施工或走无需预登录的设备邀请入口。

## 界面

![TextNodeAssistant 全部功能](dist/TextNodeAssistant-v0.9.5-gui-preview.png)

![TextNodeAssistant 图形工作流](dist/TextNodeAssistant-v0.9.5-workflow-preview.png)

所有普通输入、秘密输入、Host Key 核对、Y/N、精确危险确认、日志和隧道关闭都在当前图形窗口内完成。密码使用遮罩输入，Windows SSH 密码通过当前用户专属随机命名管道交给 OpenSSH，不进入命令行参数或日志。

## 支持范围

| 范围 | 当前实现 |
|---|---|
| Windows | Windows 10/11 x64、Windows 10 x86、Windows 10/11 ARM64 |
| Android | Android 7.0+ universal APK，不依赖 Termux/WebView |
| VPS | Ubuntu / Debian，root 或可 sudo 用户，推荐 KVM、1 GB+ 内存 |
| SSH | 临时密码、节点长期 Ed25519 key、每设备独享 key、Host Key 固定 |
| 面板 | 3x-ui，仅经 `127.0.0.1` SSH 隧道打开 |
| 代理 | VLESS + REALITY 灰云直连；VLESS + XHTTP 橙云路径；可选双路 |
| 网盘 | 固定并校验供应链的 copyparty，随机 `39000—39999` 回环端口，仅经 SSH 隧道 |
| Web | Nginx、证书、15 套本地自包含伪装模板 |
| 恢复 | 原生基线快照、配置/完整备份、救援包、代理单拆、整体恢复基线 |

### Windows 包怎么选

请先按系统架构下载，三个 EXE 不是“同一个包的不同名字”：

- `TextNodeAssistant-v0.9.5-win64.exe`：Intel/AMD 64 位 Windows 10/11，绝大多数电脑使用这个。
- `TextNodeAssistant-v0.9.5-win32.exe`：只有明确安装了 32 位 Windows 时使用。
- `TextNodeAssistant-v0.9.5-win-arm64.exe`：只给 Snapdragon 等 Windows on ARM64 设备使用。

ARM64 包内嵌的是 ARM64 版 rclone；在普通 Intel/AMD Windows 上运行它会弹出“映像文件无效，但它对另一种计算机类型有效”。这不是 VPS 或账号故障，关闭该包并改用 `win64` 即可。下载后请同时核对 `SHA256SUMS-v0.9.5.txt`。

## 从零开始：最短可靠流程

1. 准备带独立公网 IPv4、可进入厂商 Console/VNC 的 Ubuntu/Debian VPS。
2. 准备一个已接入 Cloudflare 的域名。
3. 下载与你系统匹配的 EXE 或正式 APK，核对 `SHA256SUMS-v0.9.5.txt`。
4. 首次启动创建本机 `admin`，立即把恢复包和恢复码分开保存。
5. 进入高级控制台，选择 `[1]`。
6. 选择临时密码或该节点长期 key，输入 VPS、SSH 用户和端口，核对厂商 Host Key 指纹。
7. 程序检测/迁移工具包、保存原生基线并更新设备密钥后，必须明确选择拓扑：

| 选择 | 需要准备 | 优点 | 代价 |
|---|---|---|---|
| `[1]` 仅灰云 | 1 个 DNS-only 子域名 + 邮箱 | 路径短、通常延迟最低 | 客户端可见源站 IP |
| `[2]` 仅橙云 | 1 个 Proxied 子域名 + 邮箱 | 客户端只使用 Cloudflare/XHTTP | 多一层边缘，必须配置 Cloudflare |
| `[3]` 双路 | 1 个灰云 + 1 个橙云子域名，各自邮箱 | 两条独立订阅，故障切换最稳 | 配置最多 |
| `[0]` 保持 | 仅既有受管节点显示 | 不改当前拓扑 | 不能用于新机或已拆除拓扑 |

8. 灰云域名必须由公共 DNS 指向 VPS；橙云域名必须打开 Cloudflare 代理。
9. 橙云/双路会逐项引导确认：Universal SSL 可用、`Full (strict)`、客户端使用 Cloudflare 免费支持的 `8443` 端口、Cache Rule 对该 hostname `Bypass cache`，且不挂 Access/质询/重定向/Worker。每项完成后回程序按 Enter；输入 `q` 安全停止。
10. 程序强制安装并验收回环网盘，然后施工代理；橙云路径必须导入 `8443` XHTTP 链接并真实浏览，输入精确确认后才提交。
11. 程序创建首个 controller、保存本机加密 admin 能力、生成完整交接单并原子提交；失败会回滚整次事务。
12. 保存交接单、清空剪贴板，分别打开网盘和 3x-ui 隧道做最终检查。

完整购买、Cloudflare 和排障步骤见[从零部署教程](TextNodeAssistant-v0.9.5-从零部署教程.md)。

## Cloudflare 要点

双路必须使用两个不同子域名。同一条 DNS 记录无法同时保持 DNS-only 和 Proxied，但已经施工的节点可以通过 `[1]` 在仅灰云、仅橙云和双路之间收敛切换。

橙云链路的实际路径是：

```text
客户端 HTTPS:8443
  → Cloudflare Edge :8443
  → VPS:8443
  → 仅允许 Cloudflare 官方 CIDR 的 Nginx
  → 回环 XHTTP 入站
```

Cloudflare Universal SSL 解决客户端到 Cloudflare Edge 的证书；`Full (strict)` 仍要求 VPS 源站提供该 hostname 的有效证书。程序使用 Cloudflare 免费支持的 Edge :8443，源站同为 :8443，不依赖付费 Origin Rule；随后证明 `Cf-Ray`、受管源站标记和外部直连 8443 被拒。

若 Windows 开着 v2rayN TUN，公共 DNS 探测可能被本机代理劫持。程序会明确提示暂停 TUN/VPN 后重测，不会把本地 DNS 故障误判成 Cloudflare 配置错误。

### 面板复制的 XHTTP 链接

回环 XHTTP 入站在 VPS 内部必须保持 `security=none`；橙云客户端入口则必须是公网 TLS。TNA 会为受管入站同步 `externalProxy.forceTls=tls` 和 `tna-cdn-xhttp` HostGroup，使 3x-ui 的“入站详情/分享”生成公网 hostname、SNI、Host、路径、`fp=chrome` 和 `:8443`。如果复制出的链接仍显示 `security=none`、SNI/Host 为空或出现回环端口，说明页面或链接是旧快照：刷新 3x-ui（Ctrl+F5）后从入站详情重新复制，或重新更新 TNA 的受管订阅。已经导入客户端的旧节点不会自动变更，必须删除旧节点再导入新链接。

## SSH 与设备准入

每项远端操作都重新选择目标与认证方式，不会绑死上一台 VPS。

| 模式 | 行为 |
|---|---|
| 临时密码 | 密码只在当前会话内使用；一次性 key 在该项结束时撤销并删除 |
| 节点长期 key | 按稳定节点 + SSH 用户隔离；新 key 真登录成功后才替换旧 key |

新设备不需要先获得服务器密码：

1. 已有 controller 在 `[20]` 创建“绑定成功后才失效”的邀请。
2. 新设备首页选 `[J]`，粘贴邀请并生成本机独享身份、SSH key 和响应。
3. controller 在 `[20]` 批准响应，设备进入 `pending-verification`；若网络中断可重试，邀请尚未消费。
4. 新设备回到 `[J]` 完成首次真实 key 登录；成功后设备激活，邀请才失效。

严格安全模式关闭公网 SSH 密码后，未获准设备的普通 SSH 会被拒绝；厂商 VNC/串口/救援 Console 仍是兜底。订阅与“能否 SSH 管理服务器”是两套权限：每设备 VLESS 可以独立暂停/吊销，但不是不可复制的硬件锁。

## 高级控制台功能

| 编号 | 功能 | 边界 |
|---:|---|---|
| 1 | 安装 / 升级 / 恢复 / 拓扑收敛 | 唯一施工入口；同构建跳过、旧构建升级、新构建拒绝降级 |
| 2 | 打开 3x-ui | 本机随机端口 SSH 隧道 |
| 3–4 | 体检 / 安全修复 | 结构化检查；修复前备份 |
| 5–7 | VPS/面板凭据 | 真实回读；完整交接单才可显示 |
| 8 | 伪装网站 | 15 套本地模板，随机/稳定/指定 |
| 9–10 | 灾备 / 紧急报告 | 下载到本机，分享前人工脱敏 |
| 11 | SSH key | 先验证新钥再撤旧钥 |
| 13 | 卸载远端工具包 | 保留节点、配置、凭据和备份，不触发重装 |
| 15–17 | 备份整理 / 性能 / 流量 | 可回滚配置；vnStat 不冒充厂商账单 |
| 18 | 拆除施工和恢复基线 | 先救援；仅拆代理保留强制网盘，或整体恢复原生基线 |
| 19 | 安全事件 | 有界、脱敏读取 SSH/Fail2ban/防火墙元数据 |
| 20 / J | 设备准入 | 首个 controller、邀请、批准、首次绑定、暂停/恢复/吊销 |
| 21 | 强制网盘 | 隧道、admin 能力、普通账号、改密、恢复凭据 |
| 22 | 线路拓扑只读状态 | 不施工；所有拓扑改动回到 `[1]` |
| 23 | 公网 IP 重绑定 | Host Key、machine-id、NODE_ID、SERVER_ID 全匹配才提交 |
| A / B | 本机 admin | 内层改密/恢复包；门禁开关与会话超时 |

## 拆除与恢复

`[18]` 固定名称为“拆除施工和恢复基线”。执行前先生成、下载并校验救援包。

- 代理仍存在：可“仅拆代理、保留强制网盘”，或“整体拆除并恢复原生基线”；
- 只剩网盘：才显示“拆除剩余网盘并恢复基线”；
- 完整拆除：撤销代理、网盘和全部 TNA 施工，最后处理当前 controller，SSH/厂商 Console 救援路径优先保留；
- 旧节点没有可信原生快照时，界面必须明确显示 `LEGACY_UNCERTAIN`，不得谎称逐字节还原。

重新施工只运行 `[1]`。它会读取基线、拆除回执和现场组件，只恢复缺失部分或执行完整收敛。

## 凭据与隐私

运行态秘密分别保存：

| 数据 | Windows | Android |
|---|---|---|
| 本机 admin | Credential Manager/DPAPI + 加盐验证器 + `.tna` 恢复包 | Android Keystore 加密应用仓 + 恢复导出 |
| 节点 SSH key | 当前用户 ACL 隔离的 TNA 目录；旧版目录只读迁移 | Android Keystore 加密应用仓 |
| 网盘 admin 能力 | Credential Manager，按 NODE_ID 隔离 | Android Keystore 加密应用仓 |
| 普通网盘凭据恢复 | 每个 controller 的 X25519 加密信封；VPS 不保存明文 | 同左 |
| SSH 密码 | 随机命名管道，只存当前会话 | 只存当前会话内存 |

公开包禁止出现真实 IP、域名、邮箱、密码、API Token、SSH 私钥、REALITY 私钥、完整订阅或未脱敏交接单。发布前会扫描源码、EXE/APK、ZIP、TAR 和解包内容。

## 构建与发布

```powershell
# Windows x64：完整测试与运行时冒烟
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Architecture amd64

# Android 测试与签名 release
cd android
.\build-android.ps1 -Task Test
.\build-signed-release.ps1
```

双击 `build-all-pc.bat` 可构建 Windows x64、x86、ARM64，随后由 `package.ps1` 生成便携包、源码包、哈希和 SBOM。具体依赖、交叉编译边界与签名说明见 [BUILD.md](BUILD.md)。

## 常见故障

| 症状 | 处理 |
|---|---|
| DNS 一直重检 | 暂停 v2rayN TUN/VPN；用 1.1.1.1 与 8.8.8.8 复查公共 DNS |
| 橙云边缘失败 | 核对 Proxied、Universal SSL、Full (strict)、客户端是否使用 :8443、Cache Bypass |
| SSH 密码拒绝 | 核对用户、大小写、粘贴空格和厂商是否禁用 root 密码；必要时用 Console 重置 |
| Host Key 改变 | 先在厂商后台核对重装/迁移，禁止盲目接受 |
| 面板/网盘白屏 | 保持 TNA 运行；只能使用程序给出的 `127.0.0.1:随机端口`；关闭时点专用隧道按钮 |
| 输入区不响应 | 等待完整结构化提示；秘密框/普通框会按提示切换；安全停止会有限退出 |
| 订阅延迟 -1 | 使用 `[20] → [9]` 的当前设备最新链接，检查设备状态、443/8443、防火墙与客户端核心 |

详细失败树见[完整使用说明书](TextNodeAssistant-v0.9.5-完整使用说明书.md)和 [REPRODUCTION-AND-FIX.md](REPRODUCTION-AND-FIX.md)。

## 目录

```text
gui/                                  Windows WPF 外层网盘与内层控制台
android/                              Android 原生客户端
runbook/text-node-assistant-v0.9.5/   Linux 工具包与 15 套模板
scripts/                              Shell/GUI/协议静态门禁与真机测试入口
*.go                                  Windows 工作流、状态机、凭据和恢复逻辑
```

MIT License。详见 [LICENSE](LICENSE)。
