# ProxyNodeAssistant macOS package

当前推荐的构建脚本是 `build-macos-gui-pkg.sh`。它生成
`ProxyNodeAssistant-v1.0.0-macos-gui-user.pkg`：这是原生 SwiftUI 图形客户端，不是把 CLI 套在 Terminal 外面。

## 当前 GUI 包

- 界面按 Windows 正式 GUI 的真实结构重做：总览、安装与升级、面板与访问、维护与修复、安全与凭据、备份与报告、本机工具；共 26 个操作卡片；
- 点击操作后进入同窗口工作区，显示本次连接草稿、运行日志和动态输入区；
- `[12]` 清空剪贴板、`[14]` macOS 系统级 10808 代理、`[T]` 服务商流量中心、`[H]` 登录历史和 `[K]` 多 key 管理均从本机工作区开始；`[14]` 配置前保存当前系统 HTTP/HTTPS/SOCKS、旁路和 PAC/WPAD 设置，切换到 127.0.0.1:10808 并关闭 PAC/WPAD，撤销或恢复时还原原设置，修改时只请求 macOS 管理员授权，不连接 VPS；这些工作区只显示“仅本机”说明，不展示 VPS、SSH 用户、端口或密码字段，也不会发起 SSH；
- 连接表单现在是真实的 SSH 输入源：启动后会按 CLI 的实际顺序自动提交认证方式、历史选择 `M`、VPS 地址、SSH 用户和端口，不会再把 `Y/N` 或其他快捷键误当成主机；临时密码模式的密码只建立本次一次性会话 key，操作结束、失败、取消或中断都会撤销远端临时公钥并删除本机临时 key；
- 连接面板提供可选的“VPS 登录密码 / 首次绑定密码”安全字段：密码只留在本次进程内存，CLI 发出真实 SSH 密码提示时自动提交；留空时仍可在下方遮罩框输入。长期 key 首次验证成功后，GUI 会自动确认绑定当前 `VPS 主机 + SSH 用户`，后续操作直接复用该范围的 key。SSH 握手成功后，总览会显示真实的已连接主机，认证拒绝会标记为“认证失败”而不会伪报“已完成”；
- 面板打开流程已修复为单次只读 SSH 预检：工具包完整性、`18-panel-metadata.sh` 和交接信息在同一条已认证连接中读取，避免连续新建 SSH 触发 VPS 连接频控导致“panel metadata command failed / Operation timed out”。macOS 每项远端操作会建立短期 OpenSSH 控制会话并复用首个认证连接；面板转发通过同一已验证控制会话的 `ssh -O forward` 创建、通过 `ssh -O cancel` 关闭，不再启动第二条 SSH 登录。面板元数据仍必须通过远端脚本返回的端口和路径校验，绝不手猜端口；隧道启动失败会在有限等待后明确结束，不会无限卡住；
- 所有非交互的 `ssh`、`scp` 和 Host key 探测都有 30 秒进程级截止时间；SSH 接受 TCP 但卡在 banner 或认证阶段时会返回可读诊断并结束本次操作。SwiftUI 还会在 macOS 漏发子进程退出事件时主动收尾，清除“运行中”状态，不会留下假运行的窗口。
- 长期 SSH key 由 CLI 按 `VPS 主机 + SSH 用户` 分别管理，支持多节点、多用户、多把 key；“面板与访问”中的“管理已绑定 key”直达真实 `[K]` 查看、恢复和归档流程，不读取或覆盖私钥；
- 总览的“新增 key”会进入 `[11]` 绑定/重新生成流程；列出绑定后，每条真实 key 都有独立的“解绑”按钮，解绑前由 GUI 再确认，CLI 会把本机 key 移入可恢复备份；
- 通过 Darwin CLI 的 `PNA_GUI_MODE=1`、`PNA_GUI_PROMPT_B64`、`PNA_GUI_SECRET_B64` 以及 OpenSSH 密码交接公告接管提示，密码使用遮罩输入，不写入参数、日志或磁盘；
- 凭据交接单 `[7]` 会在完整性校验通过后通过 macOS `pbcopy` 写入本地系统剪贴板，并用 `pbpaste` 回读做字节级一致性校验；回读不一致会明确报错，不会伪报“已复制”。GUI 日志只显示“已复制”和非秘密路径提示；“保存好以后按 Enter”完成后会显示可见的“是否清空含秘密的剪贴板” Y/N 选择，选 `N` 可先粘贴到密码管理器，粘贴完成后再运行本机 `[12]` 清空。无人操作时有有限安全超时，不会因隐藏的自动回答让交接单刚复制就消失；两台 VPS 应分别运行 `[7]` 验收，确认剪贴板非空后立即清理；
- 打开 3x-ui 时识别 CLI 的本地回环隧道保持状态，并在工作区标题栏和输入区显示“关闭面板隧道”；按钮提交 CLI 保持提示要求的空行（等同于按一次 Enter），收到 `PNA_GUI_TUNNEL_CLOSE_ACK`（兼容 `TNA_GUI_TUNNEL_CLOSE_ACK`）后才确认关闭，5 秒未确认会走安全停止和临时凭据清理；
- CLI 以通用二进制随应用附带，支持 Apple Silicon `arm64` 和 Intel `x86_64`；
- 远端施工仍遵守原工具的先预览、先备份、精确 `APPLY` 和失败关闭语义。

## 安装位置与卸载

这是用户级 `.pkg`。安装时使用 macOS 的 `CurrentUserHomeDirectory` 目标，应用落在：

```text
~/Applications/ProxyNodeAssistant.app
```

安装包不写入 `/usr/local/bin`、`/Applications` 或其他系统目录，也不会注册系统级安装收据。可以从 Finder 的“前往文件夹…”打开 `~/Applications`，或从 Launchpad / Spotlight 启动。

卸载有两种方式：

1. 直接把 `~/Applications/ProxyNodeAssistant.app` 拖到废纸篓；
2. 打开应用的“设置”，点击“卸载应用”。它会退出应用并清理应用自身目录和用户级配置；如果 `[14]` 留有系统代理快照，会先弹出 macOS 自己的授权框完成恢复，恢复失败则停止卸载。

旧版错误包留下的 `/Applications/ProxyNodeAssistant.app`、`/usr/local/bin/pna`、`/usr/local/bin/proxynodeassistant` 和 `com.greyoak111.proxynodeassistant` 收据已在本机单独精确清理；新包不会再创建这些系统级残留。

## 构建

在 macOS 上执行：

```zsh
chmod 755 macos-pkg/build-macos-gui-pkg.sh
macos-pkg/build-macos-gui-pkg.sh
```

脚本会从 `macos-pkg/sources/` 内部构建源组装通用 CLI，编译 SwiftUI 的 `arm64` / `x86_64` 图形二进制，生成图标、Info.plist、非可迁移组件描述和最终用户级 product package；这些 Darwin 压缩包不会出现在项目根目录或 macOS release 资产列表中。

旧的 `build-macos-pkg.sh` 现在只是兼容入口，会自动转到当前的用户级 GUI 构建脚本，不会再生成 Terminal 包装器或全局 CLI。
