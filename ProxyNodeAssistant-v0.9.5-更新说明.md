# ProxyNodeAssistant / proxy-runbook v0.9.5 更新说明

## CDN/XHTTP 与私人网盘阶段

- 新增 `direct-reality`、`cdn-xhttp-tls`、`dual-hot-switch` 三种持久化模式标识与失败关闭状态机；默认生产行为仍保持 `direct-reality`。
- 3x-ui 安装改为固定 release、commit 和 SHA-256，不再执行浮动 `master/main/latest` 安装入口。
- 操作 `[22]` 晋升为完整双模式控制中心：先在回环创建 VLESS + XHTTP `packet-up` 与 `127.0.0.2:8443` 影子，再可事务化应用 Cloudflare 官方 CIDR 的 8443 UFW 锁源，并让 Nginx 同时监听“VPS 的明确公网 IPv4:8443 + 127.0.0.2:8443”。不会使用会抢占现有回环后端的 `0.0.0.0:8443`；SSH 与 Reality 443 永不由该事务修改。
- Cloudflare 侧保持人工：橙云、`Full (strict)`、Origin Rule `443 → 8443`、整 hostname Cache Bypass；程序不收集 Token。Windows/Android 与 VPS 双端验证 DNS 只返回 Cloudflare、`Cf-Ray`、受管源站标记和外部直连 8443 被拒后，才释放生产 443 XHTTP 链接。
- 真实客户端浏览后必须输入 `REAL BROWSE OK` 才提交 `DUAL_INSTALLED_ACTIVE_CDN`；可以只撤回公网 8443/UFW而保留回环影子，也可以全删 CDN/XHTTP 回到 `ACTIVE_DIRECT`。Reality 443 全程保留。
- Windows 与 Android 都使用严格 XHTTP 链接解析器，拒绝缺失/重复字段、TLS 降级、错误 hostname/path/port 和非 `packet-up` 模式；不信任 3x-ui 自动分享链接。
- 新增操作 `[21]`：固定 copyparty v1.20.21 SFX 的 URL、大小和 SHA-256，以非 root systemd 用户运行，只监听 `127.0.0.1:3923`，提供 2/3GiB 有界配额、磁盘保留门、SSH 隧道、凭据轮换和保留文件卷卸载。
- 网盘明文密码仅通过受保护 stdin 进入远端哈希器；远端配置只保存 scrypt 哈希。新凭据只有在无 Cookie 登录、上传、下载、匿名拒绝、删除和删除后复查全部通过后才进入受保护交接区。
- 灾备、诊断、安全修复与全量拆除已识别新增组件；普通卸载默认保留用户文件，永久清空需要双重精确确认。
- 旧 v0.9.0 交接单黄金 fixture 保证字节级前缀兼容；v0.9.5 只在后方追加结构化状态，不重排或丢弃未知旧字段。
- 新增 `[19]` 安全事件：受管 Fail2ban jail 不再只看 daemon active，而是校验配置、reload 和 `status sshd`；日志按类别有界聚合且不记录秘密路径、UUID 或载荷。
- 新增 `[20]` 设备准入：本机 Ed25519 身份、十分钟单次签名邀请、每设备 VLESS、重放拒绝、暂停/恢复/吊销和最后控制器保护。设备事务异常退出会回滚 3x-ui 入站与注册表，撤销回滚失败明确标记 `REVOCATION_PARTIAL`。
- 新增 `[23]` 公网 IP 重绑定：复用原 SSH key，固定旧 Host Key，并核对 machine-id、`NODE_ID` / `SERVER_ID`；缺少记录、公钥被拒和 Host Key 不同为三个独立失败。直接 DNS 成功后才提交新 endpoint；橙云或联合换域名停在人工 Cloudflare 阶段。
- Windows 与 Android 的 `[1]`、`[5]`、`[6]`、`[7]`、`[23]` 统一使用追加式完整交接渲染器；远端旧交接原文仍是字节级前缀，Cloudflare Token 永不进入交接。

revision 12 已具备人工 Cloudflare 配置后的 CDN/XHTTP 生产验收能力，并补齐 Ubuntu 22.04 / UFW 0.36.1 对 IPv6 `insert 1` 不兼容时的 `prepend` 规则排序，以及 Cloudflare 官方 CIDR 文件末行无换行符时的准确回读计数。它不会替用户点击 Cloudflare、不会保存 API Token，也不会在未验证时宣称源站隐藏。历史暴露状态与实时锁源状态分开报告。应用版本永久固定为 `v0.9.5`，后续只递增内部 `TOOLKIT_BUILD_REVISION`；`v1.0.0` 留给未来真正正式版。

revision 5 新增菜单 `[18]`“全量拆除与恢复基线”。执行前显示只读计划并要求高风险确认，随后在 Windows 下载并 SHA-256 校验完整救援包；只有救援包落地后才会拆除受管的 x-ui/Nginx Cover/WARP/vnStat/性能配置、证书、工具包和远端备份。SSH 配置、当前登录 key、22 端口与共享基础包始终保留，防止把 VPS 铲成失联状态。

从 revision 5 开始，首次施工会先保存原始基线。拥有精确基线的新节点可恢复施工前文件、软件存在状态和服务启停状态；旧版施工节点没有可信原始快照，只允许经第二次明确确认执行有边界的 legacy 全拆，程序不会谎称逐字节还原。

hotfix4：修复工作流中断后，旧 `reality-shadow.env` 的 `TEST_PORT` 字段未被复用探针识别，导致既有 24443 shadow 被误判并触发重复创建错误。修复后会核验并复用真实的 VLESS+REALITY 入站。

同版热修复：Nginx 重载后的 ACME 随机探针不再只请求一次。程序会在重载前写好探针，等待新 worker 真正接管后再做本机与公网双重校验，避免正常站点被瞬时旧 worker 的 404 误判为施工失败。

图形验货热修复：24443 人工确认不再使用没有换行的远端 `read -p`。远端会发送 GUI 可识别的提示帧，窗口立即提供“是/否”；ANSI 颜色码不会再显示成 `[33m`。若旧流程在这里安全停止，修正版会复用并重新显示已有 24443 shadow，不会重复创建。

同版本工具包加入递增 build revision：当前 EXE 会升级同版本旧构建；若远端 revision 更高则拒绝降级并提示更换新 EXE。

revision 7 修复 Windows 默认 DNS 解析器超时导致的无限“DNS 还没生效”误判。安装入口现在并行检查 Windows 系统解析器、Cloudflare DNS-over-HTTPS 与 Google DNS-over-HTTPS：系统解析器命中即可通过；系统失败时两个公共解析器必须同时精确命中。远端 runbook 使用相同仲裁规则，并以 `MATCH/MISS` 显示结果，不输出或保存任何 DNS API 凭据。

revision 8 取消残缺凭据交接。Windows 和 Android 的交接区最上方固定显示 `VPS_ACCOUNT`、`VPS_PASSWORD`、`PANEL_ACCOUNT`、`PANEL_PASSWORD`；任何一项缺失或为占位符都会拒绝显示和复制。远端新增权限为 600 的当前登录凭据仓，避免新一轮施工把仍有效的密码清到历史档；面板凭据必须通过 localhost 真实登录验证。若已有节点只剩密码哈希，`[1]` 会明确询问后轮换；拒绝轮换即安全停止，绝不谎报完成。

revision 9 修复 3x-ui 3.6.0 的面板密码真实验货：主施工脚本会在首次调用前加载验证库，登录探针先取得 CSRF Token 与同会话 Cookie，再按浏览器流程提交账号密码。旧版直接 POST 会被 3x-ui 返回 HTTP 403，不能再被误判成密码错误；探针失败本身不会自动改密码。

Windows 图形客户端与远端工具包从本版起统一使用 `0.9.5`。远端旧版只能由菜单 `[1]` 升级；完整同版禁止重复上传，远端版本更高时拒绝降级并提示更换更新的 EXE。

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
- 已保存节点现在可用 `[3]` 直接联网查看/刷新；只有一项时自动选择；`[4]` 可离线查看上次完整流量快照；结果页会停留等待确认。
- 旧配置没有快照时会明确要求刷新一次，不会把缺失数据错误显示成 0 流量；API Key 仍不提供明文回显。

## 图形与秘密输入

- 首页保留 `[16]`、`[17]`、`[T]`，并新增 `[21]`、`[22]` 完整图形卡；当前功能总数 23；
- `[16]`、`[17]` 使用统一的临时密码/长期 key 图形连接页；`[T]` 直接进入本地流量中心；
- 新增明确 `PNA_GUI_SECRET_B64` 提示帧，API Key/Token 使用 `PasswordBox`，不会因为普通日志中出现 `token` 字样而错误解锁；
- CLI 模式关闭控制台回显后读取秘密，读取结束立即恢复；
- 原有关闭面板隧道、恢复 key、EOF 防忙循环、暗色滚动条和全图形输入回归全部保留。

## 远端工具包完整性

v0.9.5 同版完整性探针除原有部署、面板元数据、备份和 15 套伪装站外，还要求：

```text
linux/20-adaptive-performance.sh
linux/21-traffic-status.sh
linux/04f-xhttp-cdn-api.sh
linux/05e-cdn-xhttp-nginx.sh
linux/05f-cloudflare-origin-lock.sh
linux/05g-cdn-xhttp-validate.sh
linux/29-copyparty-drive.sh
linux/30-copyparty-account.sh
linux/31-copyparty-nginx.sh
```

任一缺失都不会被误判为可复用的完整同版。远端卸载仍只删除本工具已知目录、`proxy-node` 启动器和上传残留，不删除 x-ui/Xray、Nginx、WARP、证书、站点、节点配置、凭据或备份。

## 验证与交付

发布构建执行：Go 单元测试与 vet、全部 Shell `bash -n`、runbook 内部 SHA-256 清单、WPF 首页/工作区渲染、全图形工作流、秘密 AskPass、提示帧、关闭输入防忙循环、面板隧道真实点击、历史目标和发布包隐私扫描。

最终文件名：

```text
ProxyNodeAssistant-v0.9.5-win64.exe
ProxyNodeAssistant-v0.9.5-win32.exe
ProxyNodeAssistant-v0.9.5-win-arm64.exe
ProxyNodeAssistant-v0.9.5-便携包.zip
ProxyNodeAssistant-v0.9.5-source.zip
proxy-runbook-toolkit-v0.9.5.tar.gz
SHA256SUMS-v0.9.5.txt
```
