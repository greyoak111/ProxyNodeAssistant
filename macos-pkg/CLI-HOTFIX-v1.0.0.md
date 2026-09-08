# v1.0.0 macOS CLI 热修说明

## 触发问题

“无感打开 3x-ui 面板”在完成密码/长期 key 验证后，继续读取面板运行元数据时如果再启动独立 SSH，连续连接可能达到 VPS 的连接频控或 fail2ban 阈值，第二条会只在 TCP 层超时，界面就停在“正在运行”。日志中的 `ssh: connect to host ... Operation timed out` 表明远端元数据脚本尚未执行。

## 修复内容

- 将远端工具包探测、`18-panel-metadata.sh` 元数据读取和交接信息导出合并到同一条只读、已认证 SSH 请求；
- macOS 每项远端操作创建 `0700` 短期 OpenSSH `ControlPath`，让首个认证连接供后续同项 SSH/SCP 复用；操作收尾先撤销一次性公钥，再发送 `ssh -O exit` 并删除 socket 目录。面板转发通过同一已验证 held control master 的 `ssh -O forward` 建立、`ssh -O cancel` 关闭，控制会话生命周期绑定隧道，只有关闭面板隧道时才清理，不会因普通 CLI 操作收尾被误关；
- 继续使用远端脚本返回的 `PANEL_PORT` 与 `WEB_BASE_PATH`，端口/路径校验失败时立即失败关闭；
- 首条带 `ControlPath` 的 OpenSSH 会话若在 macOS 上留下失效的本地控制 socket，会先确认 socket 不可用，再只清理本工具的 `/tmp/pna-ssh-*/c` 残留并重试一次；活跃 socket 不会被删除，也不会因此额外发起第三条登录连接；
- 失败状态会覆盖旧的“已连接”徽章，显示“上次失败”，避免把认证成功误报成整项操作成功；
- 认证输出中确认绑定长期 key 时立即同步本机多 key 列表，即使后续面板步骤失败也不会丢失绑定状态；
- 所有非交互的 `ssh` / `scp` / `ssh-keyscan` 捕获调用增加 30 秒进程级截止时间；SSH 接受 TCP 但卡在 banner 或认证阶段时会明确结束并返回诊断，不再无限等待；交互式密码输入仍由 PTY 保持可用。
- SwiftUI 对 PTY 子进程增加独立 `waitUntilExit` 收尾兜底；即使 macOS 没有派发 `terminationHandler`，界面也会清除“运行中”、显示失败状态并释放输入管道。读到已保存 Host 指纹后会显示“正在验证 SSH key…”以标明当前阶段。
- 版本号保持 `1.0.0`，没有改变远端工具包版本协议。

## 构建与校验

本包内的两个 Darwin CLI 归档已经替换为上述修订构建，仍保持原文件名和顶层可执行文件结构：

```text
ProxyNodeAssistant-v1.0.0-cli-darwin-arm64.tar.gz
ProxyNodeAssistant-v1.0.0-cli-darwin-amd64.tar.gz
```

SwiftUI 图形客户端由 `macos-pkg/build-macos-gui-pkg.sh` 重新编译为通用 `arm64 + x86_64`，包版本仍为 `1.0.0`。构建后执行了：

- `go build` Darwin arm64/amd64（`CGO_ENABLED=0`, `-trimpath`, `-ldflags '-s -w'`）；
- `go test -run TestPanelPreflightCommandBatchesReadOnlySSHSteps`；
- 从最终 `.pkg` payload 提取应用后执行 `codesign --verify --deep --strict`（通过）；`pkgutil --check-signature` 确认安装包本身为 unsigned，payload 内应用为 ad hoc 签名（仅用于本机用户级安装）；
- 本机不可达 `127.0.0.1:1` 回归：流程在明确的 `SSH 未就绪` 处结束，顶部状态显示“上次失败”，没有卡死；
- 解析最终 `.pkg` 的 `Distribution` / `PackageInfo`，确认 `CFBundleShortVersionString=1.0.0`；应用、内置 CLI 和 PTY bridge 均为 `x86_64 arm64` 通用 Mach-O。
- 最终包 SHA-256：`83f743b56a9726e09fb91cd85f406dd28900cb29fda2f573b58389970a8ffaa0`，并已通过 `shasum -a 256 -c SHA256SUMS-macos-pkg-gui-user.txt`。
- 当前 Darwin CLI 源包 SHA-256：arm64 `2c82552142cf3e3f9c825dd109aa40ded35db9d8ac1eab6dbbf584c368ada0dd`；amd64 `d585fdba488bc6d3f621b50c57e79e147e6b3ff3feeb9b4e802f1c06e847d87b`。

最终安装包的 SHA-256 记录在项目根目录的 `SHA256SUMS-macos-pkg-gui-user.txt`。

对应的 Go 源码差异保存在同目录的 `cli-hotfix.patch`，可对上游 v1.0.0 的 `remote.go` 和 `operations.go` 复核；补丁文件保留了早期独立隧道方案的历史差异，当前发布源码已进一步收口为 held control master 上的 `ssh -O forward/-O cancel`；发布包没有改版本号。
