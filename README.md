# ProxyNodeAssistant v0.9.0

> Android 原生完整移植已经加入本仓库：Kotlin + Jetpack Compose 全图形界面，不依赖 Termux，不弹终端，复用同一份 proxy-runbook v0.9.0。安装、认证模式、Host Key、面板隧道、密钥仓、15 套伪装、备份/报告、性能档、流量查询和全量拆除均在应用内完成。构建与使用见 [ANDROID.md](ANDROID.md)。

当前 v0.9.0 构建包含 Nginx reload/ACME 预检竞态热修复：随机 challenge 会在 reload 前创建，随后等待本机和公网均稳定读取成功，失败退出时也会自动删除探针。

当前构建同时修复 24443 图形验货死锁：远端人工确认使用带换行的 Base64 GUI 提示帧，Windows 日志剥离 ANSI；安全停止后重跑会复用已有测试 shadow。递增 build revision 让 `[1]` 能更新同版本旧构建并拒绝同版本降级。

v0.9.0 将 Windows 客户端与远端 proxy-runbook 同步为同一版本，并新增 `[16]` 可回滚自适应性能档、`[17]` SSH/vnStat 流量估算、`[18]` 救援包优先的全量拆除/原始基线恢复、`[T]` KiwiVM/条件式服务商 API 流量中心。流量预警阈值为 70/85/95%；服务商 API Key/Token 只允许本次遮罩输入，或经本人确认保存到 Windows Credential Manager，绝不保存服务商网站密码。

v0.9.0 修复“关闭面板隧道”按钮无响应：旧版在隧道标记出现后过早显示可点击按钮，但上一项输入锁尚未释放，点击发出的空行在进入后端前被丢弃。现在按钮只在后端真正进入关闭等待点后启用，点击会提交关闭指令、等待确认并清除隧道状态。构建回归会实际触发 WPF `Button.Click` 并要求隐藏操作核心正常退出，不再只检查按钮外观。

v0.9.0 / proxy-runbook v0.9.0 新增 15 套真正独立的响应式伪装站模板。菜单 `[1]` 与 `[8]` 都会显示模板清单，可选 `R` 随机、`A` 按域名稳定选择，或输入 `1—15` 精确指定。随机模式会尽量避开当前模板。第 15 套 `Signal Runner` 是原创的本地像素跑酷小游戏，不使用 Google 图像、商标或外部游戏代码。全部模板无 CDN、外部字体、统计脚本、远程图片或第三方 JavaScript。

v0.9.0 把首页和工作流界面进一步改为工业运维终端：全部主容器和操作卡使用硬边框，侧栏改成编号控制矩阵，卡片采用统一冷青状态轨、`OP:xx`、`REMOTE/LOCAL` 与 `EXECUTE` 协议标签，压低装饰色和圆角。WPF 的纵向/横向 `ScrollBar`、轨道、滑块、悬停和拖动状态均为本软件自绘，首页、日志框、下拉列表不再出现系统白色滚动条。

v0.9.0 修复图形工作流在必填提示处点击“安全停止”后，本地操作核心因标准输入 EOF 仍反复执行 `required()` 而高速刷屏、占满单核 CPU 的问题。关闭输入现在是明确的终止条件；必填空值先在 GUI 内拦截，普通提交在下一条真实交互提示出现前保持锁定，避免双击或按键连发把空行堆入后端。

v0.9.0 把 Windows 客户端改为更克制的专业运维控制台：石墨黑/冷青配色、紧凑操作卡、等宽状态标签、明确的控制平面层级，并换用真正透明、10 层 Windows 尺寸的原创节点隧道图标。没有使用 Electron 或 WebView。

菜单 `[1]` 在成功显示凭据并完成剪贴板清理询问后，会先用默认 `N` 的 y/n 问题询问是否整理远端多余备份；只有明确选择 `y` 才创建一份新验证的当前配置备份并清理已知旧包，然后才询问是否打开面板。整理失败会停止后续打开面板，避免失败连锁。

`[K] → [6]` 新增全部本机归档：不登录 VPS，把绑定根目录下所有节点 key/known_hosts 整体转入 `%USERPROFILE%\.ssh\proxy-runbook-revoked\`，清空绑定位置且不自动填充。远端公钥保留；以后 `[K] → [4]` 恢复时先尝试免密码直接验证，只有远端公钥已经失效才回退到一次密码重绑。

Windows 应用与内嵌远端工具包均为 `v0.9.0`。远端旧版会由菜单 `[1]` 识别并一次升级；远端已有完整 v0.9.0 时禁止重复上传和 bootstrap，只继续自适应检查与用户明确选择的收敛操作。

GUI 内嵌经过构建时固定的 Go 操作核心。点击卡片后，同一个窗口会切换到完整操作工作区：连接方式、VPS 信息、普通输入、Host Key/人工确认、实时日志、停止和结果都在图形界面中完成，不会再弹出黑色终端。操作核心与专用 AskPass 辅助程序按版本及 SHA-256 提取到 `%LOCALAPPDATA%\ProxyNodeAssistant\v0.9.0\`；哈希不符时拒绝运行。

最近节点历史位于 `%APPDATA%\ProxyNodeAssistant\recent-targets.tsv`。长期 key 位于 `%USERPROFILE%\.ssh\proxy-runbook\`；解绑后不会销毁，而会移到 `%USERPROFILE%\.ssh\proxy-runbook-revoked\`。`[K] → [5]` 可直接在资源管理器打开这两个目录；`[K] → [4]` 是恢复入口。

v0.8.2 修复图形直达操作打开 3x-ui 后出现 `Sign in` 标题但页面全白的问题。根因是直达后台在浏览器取得 HTML 后立即正常退出，退出清理过早关闭 SSH 隧道，后续 JS/CSS 无法加载。现在不按菜单编号特判：任何成功操作只要实际创建了面板隧道（包括 `[1]` 施工结束后选择打开、`[2]` 直接打开及未来复用入口），都会进入统一“面板隧道保持中”状态。GUI 提供“关闭面板隧道”按钮；点击、退出或安全停止后才清理。

SSH、sudo 或服务商 API 需要秘密时，GUI 会临时显示 WPF 遮罩密码框。SSH 登录密码通过当前 Windows 用户专用的随机命名管道交给 AskPass；其他秘密输入只送入当前隐藏工作流的输入流。秘密不会进入命令行参数、普通日志或发布包。VPS 地址/用户/端口可作为可删除的本机历史保存，但不含密码或 key；服务商 API Key/Token 只有本人确认后才写入 Credential Manager。首页的“完整菜单”同样在图形工作区内运行。

此构建同时保留并验证 Win32-OpenSSH 9.2 `ssh-keyscan.exe` 错误选择未实现的 sntrup KEX 后无法取得 Host Key 的修复，以及远端备份整理等 v0.7.x 功能。

精确识别 sntrup 缺陷后，EXE 会立即使用同套件中不受影响的 `ssh.exe` 做一次隔离、无密码、无私钥的握手；其他扫描故障仍执行有限重试。公开 Host Key 只进入一次性临时文件，仍须核对指纹并明确确认后才保存。本机存在多套完整 OpenSSH 时优先选择可信系统目录中版本较新且能实际启动的一套。

菜单 `[15]` 使用与其他远端功能相同的“临时密码 / 节点专属长期 key / 取消”二级登录菜单。它要求输入大写 `CLEAN`，并严格按已知项目文件名清理，不扫描或删除云厂商快照、用户自定义备份或实时配置。

菜单 `[9]` 继续作为完整灾备，可能包含 x-ui 程序和身份，体积较大；v0.8.2 修复了它在压缩成功后仍留下展开目录的问题。日常整理与轻量配置留档优先使用 `[15]`。

EXE 会在显示主菜单前验证同一目录中的 `ssh.exe`、`scp.exe`、`ssh-keygen.exe`、`ssh-keyscan.exe`。缺失时只申请一次管理员权限并安装，随后检查 Windows 功能状态、文件完整性与实际启动；失败会明确退出，不会进入安装死循环。

菜单 `[14]` 只操作本机：可配置、撤销或查看当前 Windows 用户的 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY`，固定指向 `http://127.0.0.1:10808`，并检测 10808 是否已有程序监听。它不选择登录方式、不读取 VPS 信息、不发起 SSH。

Windows 单 EXE + Linux/PowerShell runbook。v0.8.2 拆开了“目标 VPS、登录方式、长期 SSH key、当前操作”四种状态，并修复了“本机 HTTP 检查为 200、Let’s Encrypt 公网 challenge 却得到 403”的漏检。所有需要连接 VPS 的菜单项都会重新选择目标，不再把一个本地 key/缓存连接绑死到后续 VPS。

同版还修复了 Cloudflare 轮换 Linux 软件包签名密钥后，旧 WARP 源在脚本第一条 `apt-get update` 就报 `NO_PUBKEY`、导致永远到不了密钥刷新步骤的问题。新流程先原子刷新官方 keyring，继续保留 APT 签名校验。

新版 3x-ui/Xray 把 UUID 包在 JSON 对象中返回时，v0.8.2 会提取真实 UUID 并严格校验；不会再生成包含整段 JSON 的无效 `vless://` 链接。

## 每项远端操作的登录方式二级菜单

```text
[1] 临时密码会话
    密码只交给 Windows OpenSSH
    生成的会话私钥不显示、不进剪贴板、不写入长期 key 目录
    为完成多条 SSH/SCP 而安装的一次性公钥，会在本项操作结束前精确撤销
    本机临时私钥和临时 known_hosts 随后删除

[2] 节点专属长期 SSH key
    按 VPS + SSH 用户分别保存
    已有 key 直接实测登录
    新机没有 key 时先临时密码验证，随后明确询问是否绑定

[0] 取消，不连接、不上传
```

每个远端菜单项都允许从最近节点历史快速选择，也可手工输入新目标；每项仍会重新选择目标和登录方式，不会静默绑死上一台 VPS。`[H]` 管理节点历史；`[K]` 查看、解绑、定位或恢复长期 key。

## 首次连接的新流程

```text
输入 VPS / SSH 用户 / 端口
→ 固定使用一套完整的 Windows OpenSSH 组件
→ ssh-keyscan 有限重试并只解析目标服务器的有效公钥
→ 遇到 Win32 sntrup 缺陷时由隔离、无凭据 ssh.exe 握手回退
→ EXE 显示真实 Host Key 指纹
→ 操作者在 EXE 自己的 [y/N] 提示中确认
→ 保存到该节点专用 known_hosts
→ 生成本项一次性 SSH key（此时不显示私钥）
→ GUI 弹出遮罩密码框，并通过用户专用随机命名管道交给 OpenSSH
→ 公钥安装并完成 SSH_KEY_OK 验证
→ 询问是否绑定为长期 key
→ 只有明确绑定后才保存、显示和复制真实长期私钥
```

OpenSSH 不再显示它自己的 Host Key `yes/no` 问题。需要初始 VPS 密码或 sudo 密码时，图形工作区会切换到遮罩密码框；密码不会出现在日志、命令行、剪贴板或磁盘中。普通文本、`y/n` 和 Enter 确认则使用工作区底部的图形输入栏与快捷按钮。

Host Key 默认不信任。程序不使用 `StrictHostKeyChecking=no`，也不会把未确认的 `accept-new` 结果写入长期文件。兼容回退只在全新的临时目录中用 `accept-new` 取得公开公钥，且禁用全部身份凭据；临时结果仍要显示指纹并由用户确认。全部后续 SSH/SCP 强制使用：

```text
UserKnownHostsFile=<节点密钥目录>\known_hosts
StrictHostKeyChecking=yes
UpdateHostKeys=no
```

主机密钥意外变化时继续失败关闭，防止中间人攻击。

## Host Key 扫描与 Win32 KEX 兼容回退

- 枚举 PATH、`%WINDIR%\System32\OpenSSH` 和 `%ProgramFiles%\OpenSSH` 中的完整套件，比较版本并选择较新且能启动的一套；
- 首次扫描无有效结果时进行两次有界重试，其中一次显式请求 RSA/ECDSA/Ed25519；
- 不再只凭 `ssh-keyscan` 的进程退出码判定；即使退出码非零，只要 stdout 中存在与目标主机、端口匹配且可验证的 Host Key，就继续显示指纹；
- 精确检测到 Win32-OpenSSH 9.2 sntrup 缺陷时立即回退；其他扫描故障三次仍失败后再用隔离临时 `known_hosts`、禁用密码/公钥/键盘交互的 `ssh.exe` 握手回退；
- 拒绝错误主机、错误端口、不支持的算法、无效 Base64、过短数据、注释和 SSH 噪声；
- 扫描与隔离回退都无有效 Host Key 时才失败关闭，并显示每次方法、退出码、有效密钥数和安全裁剪后的错误摘要；
- 不把测试地址或扫描到的公钥内置进 EXE。

## 公网 ACME 预检

证书申请前会在 webroot 中创建随机 challenge 文件，并同时验证本机 Host 路由与真实公网域名。只有两边返回完全相同的随机内容才调用 Certbot。ACME location 显式关闭继承的 Basic Auth 并允许公网读取；公网仍返回 403 时会停在 `PUBLIC_ACME_HTTP_PREFLIGHT`，提示检查实际 `nginx -T`、重复 server block 或上游过滤。

## v0.6.6 失败后的本地密钥

如果旧版已经显示了 SSH Private Key，随后在 `yes/no` 处失败，该私钥只生成在朋友的 Windows 本机，通常尚未写入 VPS。由于私钥已经出现在截图或聊天中，必须视为泄露：

- 不要继续使用截图中的私钥；
- 使用 v0.8.2 菜单 `[11]` 走密码验证并绑定新 key，或用 `[K]` 安全解绑旧 key 后重新绑定；
- 如果旧公钥曾经成功进入 VPS，使用 `[11]` 验证新 key 后移除旧公钥；
- 不要把包含私钥的截图继续转发。

## 菜单 `[1]` 的版本规则

```text
远端未安装          → 安装 EXE 内嵌版本
远端版本较旧        → 升级，验证后清理旧版程序
远端版本完全相同    → 禁止重复上传/bootstrap，继续自适应检查
同版本但文件不完整  → 不自动覆盖；提示 [13] 卸载后再回 [1]
远端版本更高        → 禁止降级；提示换用同版或更新 EXE
版本无法安全识别    → 失败关闭，不上传任何内容
```

只有 `[1]` 能安装或升级工具包。菜单 `[13]` 只卸载已知 v0.5—v0.8.3 管理工具，不删除 x-ui/Xray、Nginx、WARP、节点配置、凭据、证书、站点或备份。

## 保留的既有修复

- SSH stdout、stderr 与退出码分离；
- 远端失败后不复制交接单、不打开 panel；
- `Connection closed.` 不能作为凭据；
- panel 元数据和交接单完整性校验；
- 诊断协议和初始化 `rc=141` 修复；
- 3x-ui API Token 优先复用并实测，只在全部失效时生成一次；
- WARP 路由相同时返回 `XRAY_WARP_ROUTE_ALREADY_OPTIMAL`，不重复写配置或重启 Xray；
- 同版禁止重装、旧版升级、新版防降级；
- 安全卸载只作用于管理工具。
- 所有远端菜单统一使用临时密码/长期 key 二级选择；
- 首次密码验证后才询问绑定，拒绝绑定则自动撤销一次性公钥；
- `[K]` 支持换 VPS，以及“远端撤销 + 本机可恢复备份”的长期 key 解绑。

## 使用

运行：

```text
ProxyNodeAssistant-v0.9.0-win64.exe      Windows x64（推荐）
ProxyNodeAssistant-v0.9.0-win32.exe      Windows x86
ProxyNodeAssistant-v0.9.0-win-arm64.exe  Windows ARM64
```

首次 Host 指纹确认必须在 EXE 工作区显示的 `[y/N]` 处输入 `y`，也可使用旁边的“是/否”按钮。随后出现的密码框会显示圆点遮罩，输入完成点击“提交”。

## 源码结构

- `main.go`：菜单、双语、剪贴板和内嵌资源；
- `process.go`：隐藏子进程、重定向输入输出和实时日志流；
- `gui/ProxyNodeAssistant.Gui.cs`：单窗口工作区、图形输入、任务生命周期与安全停止；
- `gui/ProxyNodeAssistant.AskPass.cs`：通过当前用户专用随机命名管道把遮罩密码交给 OpenSSH；
- `remote.go`：统一双模式 SSH/SCP、首次绑定、可恢复解绑、Host Key 固定、版本探针和 panel 隧道；
- `operations.go`：13 项操作和失败控制流；
- `parsers.go` / `parsers_test.go`：协议、版本、交接单与回归测试；
- `runbook/proxy-runbook-v0.9.0/`：完整远端脚本。

支持 Windows 10/11 x64、Windows 10 x86、Windows 10/11 ARM64 客户端与 Ubuntu/Debian VPS。共享发布物不包含真实 VPS IP、域名、邮箱、账户、密码、SSH 私钥或交接单。

