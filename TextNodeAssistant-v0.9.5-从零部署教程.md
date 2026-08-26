# TextNodeAssistant v0.9.5 从零部署教程

这份教程面向第一次购买 VPS、第一次配置域名的人。先完整读一遍，再实际施工；不要边猜边点。

## 1. 最终会得到什么

一台完成施工的 VPS 同时提供：

- 强制安装、仅经 SSH 隧道访问的私人网盘；
- 仅经 SSH 隧道打开的 3x-ui 面板；
- 仅灰云 REALITY、仅橙云 XHTTP 或双路代理；
- Nginx 伪装网站和 15 套本地模板；
- 每设备独享 SSH key、设备节点、准入与吊销；
- 原生基线、救援包、备份、诊断、拆除和恢复能力。

## 2. 准备清单

### 2.1 Windows 或 Android 设备

- Windows 10/11，或 Android 7.0+；
- 能访问 VPS 的网络；
- Windows 端由程序一次性检查并安装 OpenSSH，安装成功后验证，失败会明确停止，不会循环；
- 一个密码管理器或离线安全笔记，用于保存交接单和恢复码。

### 2.2 VPS

推荐：

- Ubuntu 22.04/24.04 或当前 Debian；
- KVM，独立公网 IPv4；
- 1 GB 内存、10 GB 磁盘起步；
- 能打开厂商 VNC、串口或救援 Console；
- 知道 SSH 用户、端口和初始密码，或已有可用 SSH key。

购买前确认月流量、流量倍率、重置日、退款政策、端口限制和可否重装系统。OpenSSH/vnStat 只能估算网卡流量，厂商账单和套餐余量仍以服务商 API/面板为准。

### 2.3 域名与 Cloudflare

准备一个自己控制的域名，并把 Nameserver 接入 Cloudflare。施工时按模式准备子域名：

| 模式 | 子域名 |
|---|---|
| 仅灰云 | 一个 A 记录，DNS only |
| 仅橙云 | 一个 A 记录，Proxied |
| 双路 | 两个不同 A 记录：一个 DNS only，一个 Proxied |

两个子域名都指向同一台 VPS。双路不能让同一条 DNS 记录同时处于灰云和橙云，所以必须用两个不同 hostname。

## 3. 购买渠道与支付提醒

能否使用微信、支付宝或银联会随地区、风控和结算通道变化，购买前以商家结账页为准。常见可关注的渠道包括：

- VPS：搬瓦工/BandwagonHost、DMIT、V.PS、HostDare、RackNerd、Vultr、Linode/Akamai、DigitalOcean、Hetzner；
- 域名：阿里云、腾讯云、华为云、西部数码、NameSilo、Namecheap、Porkbun、Cloudflare Registrar。

国内商家通常更容易提供微信/支付宝/银联；海外商家可能通过 PayPal、信用卡或区域支付服务间接支持。不要仅因为支付方便就忽略服务条款、线路、退款、实名和滥用政策。

## 4. 安装 VPS 系统

1. 在厂商面板安装 Ubuntu 或 Debian；
2. 保存公网 IP、SSH 用户、端口和临时密码；
3. 打开厂商 Console，确认它能进入系统；
4. 在 Console 执行 `ip addr`、`ss -lntp`，确认网络和 SSH；
5. 记录厂商显示的 SSH Host Key 指纹（如果提供）。

厂商 Console 是最后救援路径。严格 SSH 模式、错误防火墙或密钥丢失时，它仍可以重置密码、修复 sshd 或恢复防火墙。

## 5. 接入 Cloudflare

1. 登录 Cloudflare，添加你的根域名；
2. 在域名注册商处把 Nameserver 改成 Cloudflare 给出的两条；
3. 等 Cloudflare 显示 Active；
4. 进入 DNS → Records；
5. 创建需要的 A 记录，内容为 VPS 公网 IPv4；
6. 灰云记录选择 DNS only；橙云记录选择 Proxied。

不要把邮箱、VPS 密码、SSH 私钥或 API Token写进 DNS 注释。

### 橙云额外设置

仅橙云或双路必须完成：

1. SSL/TLS → Overview：选择 `Full (strict)`；
2. Edge Certificates：等待 Universal SSL 证书 Active；
3. 客户端连接橙云 hostname 时使用 `8443` 端口；Cloudflare 免费计划无需 Origin Rule；
4. Rules → Cache Rules：匹配同一 hostname，选择 Bypass cache；
5. 确保该 hostname 没有 Access、Managed Challenge、跳转、Worker 或 Transform Rule 抢先处理。

不要把 `443→8443` Origin Rule 当成前置条件：很多免费计划没有该能力。本方案直接使用 Cloudflare 支持的 Edge `8443`，避免把 443 错送到 Reality。

## 6. 下载与校验软件

Windows：

```text
TextNodeAssistant-v0.9.5-win64.exe
TextNodeAssistant-v0.9.5-win32.exe
TextNodeAssistant-v0.9.5-win-arm64.exe
```

Android：

```text
TextNodeAssistant-v0.9.5-android-universal.apk
```

Windows 校验示例：

```powershell
Get-FileHash -Algorithm SHA256 .\TextNodeAssistant-v0.9.5-win64.exe
```

与 `SHA256SUMS-v0.9.5.txt` 对比，字符必须完全相同。

## 7. 首次启动与本机 admin

1. 启动应用；
2. 程序检查 OpenSSH；已安装则验证后进入首页，未安装则只尝试一次系统安装并验证；
3. 创建本机 admin；
4. 保存生成的恢复包和恢复码，二者分开存放；
5. 外层会显示“未挂载节点”，这是正常状态；
6. 使用 admin 进入外层，再次验证进入高级控制台。

本机 admin 不是 VPS root、不是 3x-ui 账号，也不是网盘普通账号。它只控制当前设备的内层权限。

## 8. 运行唯一安装入口

在高级控制台选择 `[1]`：

1. 选择临时密码或节点长期 key；
2. 输入 VPS 地址、SSH 用户、端口；
3. 核对 Host Key 指纹；
4. 如使用密码，在遮罩框输入；密码不进入命令行参数、普通日志或发布包；
5. 程序识别远端版本和构建；
6. 保存原生基线、迁移旧状态并更新当前设备 key；
7. 必须选择线路 `[1]`、`[2]` 或 `[3]`，空输入无效；只有完整旧节点可以选 `[0]` 保持。

### 仅灰云

输入灰云子域名和证书邮箱。程序会检查多个公共解析器；若 Windows 正在运行 v2rayN TUN、VPN 或系统代理，请先暂停后重测。

### 仅橙云

输入橙云子域名和证书邮箱。程序逐项提示 Cloudflare 设置；完成一项回应用继续，无法完成时输入 `q`。它会准备源站证书、8443 锁源、XHTTP 回环和 Nginx，然后要求真实客户端浏览验收。

### 双路

依次输入灰云子域名/邮箱和橙云子域名/邮箱。两条线路独立生成、独立验收、独立写入交接单。

## 9. 为什么橙云还要源站证书

Cloudflare Universal SSL 自动给橙云 hostname 提供浏览器到 Edge 的证书，但 `Full (strict)` 的 Edge 到 VPS 仍必须验证有效源站证书。程序会处理该证书，并在开放 8443 前做真实探针。

路径是：

```text
客户端 :8443 → Cloudflare Edge :8443 → VPS :8443 → Nginx → 回环 XHTTP
```

不要把 VPS 8443 对全网开放；程序会只允许 Cloudflare 官方 CIDR。

## 10. 施工中的人工确认

以下确认不能跳过：

- SSH Host Key；
- 线路模式；
- Cloudflare 各项；
- 24443 临时 REALITY 真机浏览；
- 橙云 8443 XHTTP 真机浏览；
- 保存交接单和 admin 恢复资料；
- 是否清理旧备份、是否打开面板。

安全停止会请求远端清理并在有限时间退出。若界面已明确卡死，可强制终止，然后运行 `[3]`；事务日志会让 `[1]` 识别未完成阶段。

## 11. 施工完成后验收

按顺序做：

1. 外层网盘能通过本地 SSH 隧道打开；
2. 注册一个普通网盘账号，上传、下载、删除文件；
3. 用旧密码二次确认新密码完成普通账号改密；
4. `[2]` 打开 3x-ui，确认登录页和真实账号密码；
5. 把灰云/橙云订阅导入客户端，各自真实浏览；
6. `[3]` 体检全部关键服务和端口；
7. `[7]` 检查完整交接单；
8. `[20]` 显示当前设备节点；
9. `[18]` 只查看拆除计划，不实际确认危险动作；
10. 保存救援包、恢复包和哈希。

## 12. 添加第二台设备

1. controller 在 `[20]` 创建邀请；
2. 新设备从未登录首页响应邀请；
3. 把响应交回 controller 批准；
4. 新设备完成首次真实 key 登录；
5. 邀请此时才失效；
6. 在新设备登录同一 VPS 的网盘普通账号；
7. controller 可暂停、恢复或吊销该设备。

订阅链接和 SSH 管理权不是同一权限。设备节点可暂停/吊销，但复制出去的订阅仍应按秘密处理。

## 13. 模式切换

任何灰云/橙云/双路切换都运行 `[1]`：

- 输入现有节点；
- 选择目标模式；
- 按引导补齐域名；
- 程序准备新链路并验收；
- 新链路提交后再拆旧链路；
- `[22]` 只负责显示最终状态。

不要直接在 3x-ui、Nginx 和 Cloudflare 之间手工拼接，否则状态机无法保证回滚。

## 14. 备份、拆除与重装

- `[15]` 清理多余备份并只保留当前配置备份；
- `[9]` 完整灾备体积更大；
- `[18]` 先下载并校验救援包，随后可仅拆代理保留网盘，或整体恢复原生基线；
- 代理已经不存在时才显示单独拆除剩余网盘；
- 拆完需要恢复时只运行 `[1]`，它会识别拆除回执和现场组件。

## 15. 必须保存与禁止分享

必须保存：本机 admin 恢复包/恢复码、VPS/SSH 标识、面板账号密码、设备恢复资料、网盘账号、当前订阅和救援包。

禁止公开：VPS 密码、SSH 私钥、完整交接单、面板密码、API Token、REALITY 私钥、完整订阅、设备邀请/响应、admin 恢复码、服务商 API Key。

## 16. 常见问题

- **DNS 循环失败**：关闭 TUN/VPN，清理系统代理，用公共 DNS 重测。
- **密码拒绝**：核对用户和大小写，必要时用厂商 Console 重置；不要连续试错触发 Fail2ban。
- **Host Key 失败**：确认端口/sshd；算法不兼容会由程序降级探测，指纹变化仍需人工核对。
- **面板白屏**：保持隧道运行，只打开程序给出的本地地址；关隧道用专用按钮。
- **交接单缺密码**：旧哈希不可逆，选择主动轮换；程序不会伪造。
- **订阅延迟 -1**：从当前 active 设备重新复制节点，核对服务、端口、Cloudflare 和客户端核心。
- **流量数字不一致**：vnStat 是 VPS 网卡估算，服务商面板/API 才是账单口径。

更完整的菜单、数据路径与故障树见[完整使用说明书](TextNodeAssistant-v0.9.5-完整使用说明书.md)。
