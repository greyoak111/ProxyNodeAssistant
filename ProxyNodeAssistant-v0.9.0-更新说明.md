# ProxyNodeAssistant / proxy-runbook v0.9.0 更新说明

revision 5 新增菜单 `[18]`“全量拆除与恢复基线”。执行前显示只读计划并要求高风险确认，随后在 Windows 下载并 SHA-256 校验完整救援包；只有救援包落地后才会拆除受管的 x-ui/Nginx Cover/WARP/vnStat/性能配置、证书、工具包和远端备份。SSH 配置、当前登录 key、22 端口与共享基础包始终保留，防止把 VPS 铲成失联状态。

从 revision 5 开始，首次施工会先保存原始基线。拥有精确基线的新节点可恢复施工前文件、软件存在状态和服务启停状态；旧版施工节点没有可信原始快照，只允许经第二次明确确认执行有边界的 legacy 全拆，程序不会谎称逐字节还原。

hotfix4：修复工作流中断后，旧 `reality-shadow.env` 的 `TEST_PORT` 字段未被复用探针识别，导致既有 24443 shadow 被误判并触发重复创建错误。修复后会核验并复用真实的 VLESS+REALITY 入站。

同版热修复：Nginx 重载后的 ACME 随机探针不再只请求一次。程序会在重载前写好探针，等待新 worker 真正接管后再做本机与公网双重校验，避免正常站点被瞬时旧 worker 的 404 误判为施工失败。

图形验货热修复：24443 人工确认不再使用没有换行的远端 `read -p`。远端会发送 GUI 可识别的提示帧，窗口立即提供“是/否”；ANSI 颜色码不会再显示成 `[33m`。若旧流程在这里安全停止，修正版会复用并重新显示已有 24443 shadow，不会重复创建。

同版本工具包加入递增 build revision：当前 EXE 会升级同版本旧构建；若远端 revision 更高则拒绝降级并提示更换新 EXE。

Windows 图形客户端与远端工具包从本版起统一使用 `0.9.0`。远端旧版只能由菜单 `[1]` 升级；完整同版禁止重复上传，远端版本更高时拒绝降级并提示更换更新的 EXE。

## 新增：可回滚自适应性能档

- 菜单 `[16]` 提供只读检测、自动、低内存、标准、高吞吐和回滚；
- 自动档按 RAM/vCPU 选择：不高于 1536 MB 为低配，至少 4 GB 且 4 vCPU 为高配，其余为标准；
- 管理 `fq + BBR`、socket/backlog、文件句柄、Nginx worker、swappiness，并为低配机提供有界 zram；
- 修改前保存受管文件和运行时 sysctl 原值，校验失败自动回滚；
- 完整状态与自动诊断会报告当前性能档，不会把“高配数值”强塞给 1 GB VPS。

## 新增：双口径流量中心

- 菜单 `[17]` 通过 SSH 调用 VPS 上的 vnStat，按本人输入的额度与重置日估算 RX+TX；
- 菜单 `[T]` 是纯本地功能，不登录 VPS；
- KiwiVM 使用 `getServiceInfo` 精确读取服务商计费字段、倍率和重置时间；
- SolusVM/RackNerd 仅在服务商明确提供只读 HTTPS JSON API/Token 时启用条件式适配；不保存或抓取网站密码；
- 预警固定为 70% `NOTICE`、85% `WARNING`、95% `CRITICAL`；
- API Key/Token 默认仅本次遮罩输入；只有本人确认后才写入当前 Windows 用户的 Credential Manager；
- 非秘密资料保存在 `%APPDATA%\ProxyNodeAssistant\traffic-profiles.json`，可删除单项或全部清空。

## 图形与秘密输入

- 首页新增 `[16]`、`[17]`、`[T]` 三张完整功能卡，功能总数 20；
- `[16]`、`[17]` 使用统一的临时密码/长期 key 图形连接页；`[T]` 直接进入本地流量中心；
- 新增明确 `PNA_GUI_SECRET_B64` 提示帧，API Key/Token 使用 `PasswordBox`，不会因为普通日志中出现 `token` 字样而错误解锁；
- CLI 模式关闭控制台回显后读取秘密，读取结束立即恢复；
- 原有关闭面板隧道、恢复 key、EOF 防忙循环、暗色滚动条和全图形输入回归全部保留。

## 远端工具包完整性

v0.9.0 同版完整性探针除原有部署、面板元数据、备份和 15 套伪装站外，还要求：

```text
linux/20-adaptive-performance.sh
linux/21-traffic-status.sh
```

任一缺失都不会被误判为可复用的完整同版。远端卸载仍只删除本工具已知目录、`proxy-node` 启动器和上传残留，不删除 x-ui/Xray、Nginx、WARP、证书、站点、节点配置、凭据或备份。

## 验证与交付

发布构建执行：Go 单元测试与 vet、全部 Shell `bash -n`、runbook 内部 SHA-256 清单、WPF 首页/工作区渲染、全图形工作流、秘密 AskPass、提示帧、关闭输入防忙循环、面板隧道真实点击、历史目标和发布包隐私扫描。

最终文件名：

```text
ProxyNodeAssistant-v0.9.0-win64.exe
ProxyNodeAssistant-v0.9.0-win32.exe
ProxyNodeAssistant-v0.9.0-win-arm64.exe
ProxyNodeAssistant-v0.9.0-便携包.zip
ProxyNodeAssistant-v0.9.0-source.zip
proxy-runbook-toolkit-v0.9.0.tar.gz
SHA256SUMS-v0.9.0.txt
```
