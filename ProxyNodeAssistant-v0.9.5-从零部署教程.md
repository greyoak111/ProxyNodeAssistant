# ProxyNodeAssistant v0.9.5 从零部署教程

适用对象：第一次购买 VPS、第一次购买域名、第一次使用 Cloudflare DNS 的用户  
适用客户端：Windows v0.9.5、Android v0.9.5  
教程核对日期：2026-08-23

这是一份从“什么都还没买”开始的教程。读完并按顺序完成后，你应当拥有：

- 一台自己可以控制、带公网 IPv4 的 Ubuntu/Debian VPS；
- 一个自己持有、已经接入 Cloudflare 的域名；
- 一条指向 VPS 的灰云 A 记录；
- 可用的 SSH 登录方式；
- 由 ProxyNodeAssistant v0.9.5 部署并验证过的节点、伪装站、订阅和本地面板隧道；
- 已经安全保存的凭据、SSH key 和恢复资料。

文中的 example.com、cover.example.com、203.0.113.10 和 admin@example.com 都只是保留的文档示例，不能原样使用。请替换成你自己真实购买的域名、VPS IP 和真实邮箱。教程和发布包不内置任何人的真实 VPS、域名、邮箱或凭据。

> 仅在你拥有或得到明确授权的服务器上操作，并遵守服务器所在地法律、云厂商条款和网络服务规则。不要把本工具用于未授权访问、垃圾邮件、攻击或规避平台风控。

---

## 1. 先看全流程

完整顺序如下：

1. 选择并购买 VPS；
2. 重装成受支持的干净系统；
3. 记下公网 IPv4、SSH 用户、SSH 端口和初始密码；
4. 购买域名；
5. 注册 Cloudflare 账号并开启两步验证；
6. 在 Cloudflare 添加根域名；
7. 去域名注册商把 Nameserver 换成 Cloudflare 分配的两条；
8. 等 Cloudflare 状态变成 Active；
9. 在 Cloudflare 添加灰云 A 记录，把 cover 子域名指向 VPS IPv4；
10. 在本机验证域名解析结果；
11. 启动 ProxyNodeAssistant，选择唯一安装入口；
12. 完成 SSH Host Key 确认、密码登录和可选长期 key 绑定；
13. 输入 cover 域名和 Let’s Encrypt 联系邮箱；
14. 完成安装、自适应优化、24443 真机验货、凭据交接和可选面板打开；
15. 把凭据和私钥保存进密码管理器，再导入订阅到客户端；
16. 运行自动体检，确认服务、端口、证书、订阅和流量状态。

不要跳过第 8—10 步。域名还没 Active、A 记录不是灰云、或解析到错误 IP 时就运行安装，最容易在证书公网预检阶段失败。

---

## 2. 怎样选择 VPS

### 2.1 这套工具需要什么样的 VPS

最低要求和推荐值：

| 项目 | 最低可用 | 新手推荐 |
|---|---:|---:|
| 虚拟化 | KVM | KVM |
| CPU | 1 vCPU | 1—2 vCPU |
| 内存 | 1 GB | 2 GB 更宽松 |
| 系统盘 | 10 GB | 20 GB 或以上 |
| 公网地址 | 独立公网 IPv4 | 独立公网 IPv4，可选 IPv6 |
| 系统 | Ubuntu/Debian | Ubuntu 22.04 LTS 64 位或 Debian 12 64 位 |
| 带宽 | 50 Mbps | 100 Mbps 或以上 |
| 月流量 | 按个人用途估算 | 500 GB—1 TB 起 |
| 权限 | root 或可 sudo 用户 | root，或厂商默认 sudo 用户 |

程序当前正式支持 Ubuntu/Debian。不要选 Windows Server、CentOS、AlmaLinux、Arch、OpenWrt、容器型主机或只提供网页空间的“虚拟主机”。

购买前确认商品写的是 VPS/Cloud Server/Cloud Compute，并且同时具备：

- 独立公网 IPv4，不是只有 IPv6；
- 不是共享端口的 NAT VPS；
- 可以通过 SSH 登录；
- 能重装 Ubuntu/Debian；
- 有 root，或 ubuntu/debian 等可 sudo 用户；
- 厂商后台能重置密码、VNC/Console 救援和重装系统；
- 入站 22、80、443 端口可用，出站网络没有特殊封锁；
- 允许你运行 Nginx、Xray、3x-ui 和一般 Linux 服务；
- 有明确流量额度、超量规则和续费价格。

### 2.2 机房和线路怎么选

不要只看 CPU 跑分。这个用途更看重你到机房的实际线路、晚高峰丢包、端口可用性和月流量。

- 预算有限、先学习：普通国际线路即可，先买月付或低价年付；
- 中国大陆连接到北美：美国西海岸通常比美国东海岸延迟低；
- 更在意晚高峰稳定：再考虑 CN2 GIA、AS9929、CMIN2 等中国方向优化线路；
- 主要供境外设备使用：优先选择离实际用户近的机房，不必为“中国优化”多付钱；
- 1 TB 月流量代表上传和下载是否合并计费，要看商家条款；
- “不限流量”也可能有公平使用、峰值带宽或持续占用限制；
- 住宅/双 ISP IP 不是本工具的必要条件，不要为了不相关标签多花钱。

[VPSDeck 的选购文章](https://vpsdeck.com/cheap-cost-effective-vps/)可以用来了解搬瓦工、DMIT、RackNerd 等常见商家和线路术语，但它属于第三方测评/推广信息。价格、库存、线路和支付方式最终以厂商官网、服务条款和实际结账页为准。

### 2.3 新手下单时逐项怎么选

在厂商订单页按下面选择：

1. Billing Cycle：第一次优先月付；只有确认线路合适后再年付。
2. Location：选择离主要使用者较近、路由合适的地区。
3. Operating System：Ubuntu 22.04 LTS 64-bit 或 Debian 12 64-bit。
4. IPv4：必须有一个独立公网 IPv4。
5. Backups：重要节点建议购买厂商快照或备份，但它不能替代本地备份。
6. Hostname：可随意设置成不含个人隐私的名称。
7. Root Password：让厂商生成也可以，收到后立刻放进密码管理器。
8. Auto Renewal：明确知道扣款规则后再打开，并保存续费日期。

不要把“VPS 商家账户密码”“VPS root 密码”“Cloudflare 密码”“域名商密码”设成同一个。

### 2.4 到手后必须保存的信息

建议在密码管理器新建一条记录：

~~~text
节点显示名：
VPS 厂商：
厂商控制台网址：
订单号：
续费日期和续费价：
机房：
公网 IPv4：
SSH 用户：
SSH 端口：
初始密码：
厂商救援控制台入口：
流量上限和重置日：
~~~

初始密码只用于首次认证。ProxyNodeAssistant 不会把它写入发布包、普通日志或剪贴板；Windows 端会通过遮罩密码框交给 OpenSSH。

---

## 3. 支持微信、支付宝或银联的 VPS/云厂商

支付能力会随着账号地区、签约主体、币种、风控和结账渠道变化。下面的“支持”表示 2026-08-23 查到的官方公开说明，不表示每个国家、每个账号和每种产品都一定出现该按钮。

标记说明：

- ✅：当前官方说明明确列出；
- ◐：受签约主体、账号地区、币种或结账页影响；
- —：当前查到的官方清单没有明确列出，不等于永远不能间接支付。

| VPS/云厂商 | 微信支付 | 支付宝 | 银联 | 重要说明 |
|---|:---:|:---:|:---:|---|
| 华为云中国站 | ✅ | ✅ | ✅ | 官方计费指南列出微信、支付宝、银联；实际能力仍取决于签约主体。 |
| 腾讯云中国站 | ✅ | — | ◐ | 官方列出微信、QQ 钱包和网银；“网银”不能简单等同于所有银联渠道。 |
| Vultr | — | ✅ | ✅ | 当前官方清单列出 Alipay、UnionPay、PayPal 和银行卡，没有列出微信。 |
| 阿里云国际站 | — | ◐ | ◐ | 支付宝和银联取决于账号签约主体；银联仅部分签约主体支持。 |
| 腾讯云国际站 | ◐ | — | — | 微信仅部分签约主体/地区可见，并有交易限制。 |

官方核对链接：

- [华为云支付说明](https://support.huaweicloud.com/usermanual-billing/usermanual-billing-pdf.pdf)
- [腾讯云云服务器购买方式](https://cloud.tencent.com/document/product/213/506)
- [Vultr 当前支付方式](https://docs.vultr.com/support/platform/billing/what-payment-methods-do-you-accept)
- [阿里云国际站支付方式及签约主体限制](https://www.alibabacloud.com/help/en/user-center/instruction-of-payment-management/)
- [腾讯云国际站预付费支付方式](https://intl.cloud.tencent.com/document/product/555/51463?lang=en)

搬瓦工、DMIT、RackNerd、HostDare、V.PS、ZgoCloud 等独立 VPS 商家的支付入口变化较频繁，有些通过第三方收单或只在特定币种显示。可以把它们作为线路/价格候选，但购买前必须亲自完成以下复核：

1. 登录厂商真正的官网，不从陌生私聊链接付款；
2. 把一个最低价方案放进购物车；
3. 到付款方式最后一步确认是否真的出现支付宝、银联或微信；
4. 核对续费时是否仍能用同一方式；
5. 核对退款是原路返回、账户余额还是不退款；
6. 不因为第三方测评页的一句“支持支付宝等”就默认某个具体商家全部支持。

如果只想最省事地使用中文支付，国内大厂的境外地域通常更容易下单，但账号可能需要实名认证，价格和带宽计费也可能高于独立 VPS 商家。中国大陆地域的网站和网络服务还可能涉及备案、实名和额外合规要求；不确定时应先查厂商当前规则。

---

## 4. 怎样购买域名

### 4.1 域名和 VPS 是两件东西

- VPS 是运行 Linux 和服务的远端电脑；
- 域名是一个可读名称，例如 example.com；
- DNS 把 cover.example.com 翻译成 VPS 的公网 IP；
- Cloudflare 在本教程中负责权威 DNS 管理，但不是必须同时负责域名注册。

你可以在任意正规注册商购买域名，再把 Nameserver 改到 Cloudflare。没有必要在 VPS 商家购买域名，也没有必要把 VPS 和域名放在同一家。

### 4.2 选域名时看什么

1. 看续费价，不只看首年促销价；
2. 确认可以自定义 Nameserver；
3. 确认能管理 DNSSEC；
4. 确认注册人信息、邮箱和手机由自己控制；
5. 打开账号两步验证；
6. 能开 WHOIS/RDAP 隐私保护就开启；
7. 不买明显侵犯他人商标的域名；
8. 不在公开仓库、截图或教程里泄露个人用途域名；
9. 建议用一个子域名做 cover，例如 cover.example.com，根域名仍可保留给别的用途。

Let’s Encrypt 邮箱必须是真实可收信的邮箱，但不要求和域名同后缀。

### 4.3 支持中文支付方式的域名注册商

| 域名注册商 | 微信支付 | 支付宝 | 银联 | 说明 |
|---|:---:|:---:|:---:|---|
| 腾讯云域名 | ✅ | — | ◐ | 官方列出微信、QQ 钱包、网银和余额；需要按中国站要求完成账号/域名实名。 |
| Dynadot | — | ✅ | ✅ | 官方说明 CNY 可用支付宝或 UnionPay。 |
| NameSilo | — | ✅ | ✅ | 官方列出 Alipay 和 UnionPay credit card。 |
| Porkbun | — | ✅ | — | 官方列出 Alipay；当前公开清单未列微信和银联。 |
| 华为云中国站 | ✅ | ✅ | ✅ | 平台支付官方列出三者；具体域名后缀、实名和结账能力以下单页为准。 |

官方核对链接：

- [腾讯云域名支付方式](https://cloud.tencent.com/document/product/242/12085)
- [Dynadot 支付方式](https://www.dynadot.com/help/question/payment-methods)
- [Dynadot CNY 支付说明](https://www.dynadot.com/help/question/currencies-accepted)
- [NameSilo 支付方式](https://www.namesilo.com/payment-options)
- [Porkbun 支付方式](https://porkbun.com/support/payment_options)

银联卡、银联在线支付和云闪付二维码是不同入口。注册商只写 UnionPay card 时，不要理解成一定支持云闪付扫码。

购买成功后马上做四件事：

1. 验证注册人邮箱；
2. 开启注册商账号两步验证；
3. 保存域名到期日和续费价；
4. 确认域名状态正常、可以修改 Nameserver。

---

## 5. 把域名接入 Cloudflare

Cloudflare 官方完整接入说明见：[Set up a primary zone](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/)。

### 5.1 创建账号

1. 打开 [Cloudflare Dashboard](https://dash.cloudflare.com/)；
2. 注册并验证邮箱；
3. 使用独立高强度密码；
4. 进入个人资料的 Authentication，开启两步验证；
5. 保存恢复码，不能只留在同一部手机里。

### 5.2 添加域名

1. 登录 Cloudflare；
2. 进入 Domains；
3. 点击 Onboard a domain / Add a domain；
4. 输入根域名 example.com，不是 cover.example.com，也不要带 https://；
5. 选择 Free 计划即可完成本教程；
6. Cloudflare 会扫描已有记录；
7. 逐条核对扫描结果，邮件域名尤其要保留 MX、TXT、DKIM、SPF、DMARC 等记录。

如果这是一个刚买、没有网站和邮箱的新域名，扫描结果很少是正常的。

### 5.3 更换 Nameserver

Cloudflare 会显示两条专属于这个域名的 Nameserver，例如：

~~~text
aaaa.ns.cloudflare.com
bbbb.ns.cloudflare.com
~~~

它们只是示例。必须复制你自己 Cloudflare 页面显示的两条。

然后回到域名注册商：

1. 找到 Domain Management / Nameservers / DNS Servers；
2. 如果注册商已开启 DNSSEC，先关闭 DNSSEC；
3. 删除注册商原来的权威 Nameserver；
4. 精确填入 Cloudflare 分配的两条 Nameserver；
5. 保存。

不要在 Cloudflare 的 DNS Records 页面里新增两条 NS 记录来代替这一步。权威 Nameserver 必须在域名注册商处修改。

Cloudflare 官方警告：如果 DNSSEC 仍开着就直接换 Nameserver，域名可能暂时无法解析。等域名在 Cloudflare 变成 Active 后，再从 Cloudflare 重新启用 DNSSEC，并按页面要求把 DS 信息同步到注册商。

### 5.4 等待 Active

Cloudflare 官方说明注册商更新 Nameserver 最长可能需要 24 小时。大多数情况更快，但不要在状态还是 Pending Nameserver Update 时开始部署。

Windows 验证命令：

~~~powershell
nslookup -type=ns example.com 1.1.1.1
nslookup -type=ns example.com 8.8.8.8
~~~

正确结果应显示 Cloudflare 分配给你的两条 Nameserver。Cloudflare 控制台的域名状态还必须是 Active。

---

## 6. 把 cover 子域名指向 VPS

### 6.1 添加 A 记录

在 Cloudflare 中打开：

Domains → 你的域名 → DNS → Records → Add record

填写：

| 字段 | 示例 | 应填写什么 |
|---|---|---|
| Type | A | 选择 A |
| Name | cover | 你想使用的子域名前缀 |
| IPv4 address | 203.0.113.10 | 你的真实 VPS 公网 IPv4 |
| Proxy status | DNS only | 必须是灰色云朵 |
| TTL | Auto | 保持 Auto |

保存后完整域名是 cover.example.com。

如果同一个 Name 已经存在 A、AAAA 或 CNAME：

- 删除指向旧服务器的冲突记录；
- 没有正确配置 IPv6 时，不要保留一个指向别处的 AAAA；
- 同名 CNAME 和 A 不能同时乱用；
- 记录值只填 IP，不要填 http://、端口或路径。

### 6.2 为什么必须是灰云 DNS only

Cloudflare 的橙云 Proxied 会让连接先到 Cloudflare，再由 Cloudflare 代理标准 Web 流量。ProxyNodeAssistant 的 443 节点包含 VLESS+REALITY 原始 TCP 流量，同时证书签发前还要让公网直接读取 VPS 上的 ACME challenge。它不是一个可以直接套普通橙云 HTTP 反代的场景。

因此本教程强制要求：

~~~text
Proxy status = DNS only
云朵颜色 = 灰色
~~~

虽然 Cloudflare 的普通 HTTPS 代理支持 443，但这不代表它会透明代理任意 443/TCP 协议。Cloudflare 官方也说明，绕过其代理并直接连接源站时应使用 gray-clouded DNS only；任意 TCP/UDP 代理属于 Spectrum 等不同产品。参考：[Cloudflare 支持的网络端口](https://developers.cloudflare.com/fundamentals/reference/network-ports/)。

### 6.3 v0.9.5 的 Experimental CDN/XHTTP 说明

上面的灰云要求仍是菜单 `[1]` 默认 REALITY 生产安装的唯一正确选择。v0.9.5 另外提供菜单 `[22]`，用于在不改变现有节点的前提下预装 XHTTP：Xray 仅监听 VPS 回环地址，Nginx 仅监听 `127.0.0.2:8443`。该步骤不修改 Cloudflare、DNS、防火墙或公网 443，也不会让新链接立即可用。

只有界面明确进入后续人工 Cloudflare 阶段，才会要求把一个独立施工 hostname 改成橙云并进行源站锁定、Full Strict、外部边缘探针和真实客户端验收。当前正式构建把这些动作标为 `WAITING_FOR_CLOUDFLARE_MANUAL_ACTION` / `PRODUCTION_443_PROMOTION=BLOCKED`；不要自行把现有 REALITY hostname 直接切成橙云，也不要把只读防火墙计划当成已应用。

### 6.4 验证 A 记录

先在 PowerShell 设置示例变量为你的真实值：

~~~powershell
$CoverDomain = "cover.example.com"
$ExpectedVpsIp = "203.0.113.10"
Resolve-DnsName $CoverDomain -Type A -Server 1.1.1.1
nslookup $CoverDomain 1.1.1.1
~~~

检查：

- 返回的是你 VPS 的公网 IPv4；
- 没有返回 Cloudflare 的代理 IP；
- 没有返回旧 VPS；
- Cloudflare 记录是灰云；
- 至少用 1.1.1.1 和 8.8.8.8 各查一次。

如果本机仍缓存旧结果：

~~~powershell
ipconfig /flushdns
~~~

然后重新查询。只有解析正确才继续。

---

## 7. 准备 VPS 系统和端口

### 7.1 建议先重装干净系统

如果 VPS 曾被其他一键脚本反复安装、443 被未知服务占用、Nginx 配置混乱，最稳妥的发布前做法是：

1. 在厂商控制台做快照或导出需要的数据；
2. 使用 Reinstall OS；
3. 选择 Ubuntu 22.04 LTS 64-bit 或 Debian 12 64-bit；
4. 等重装完成；
5. 记录新密码；
6. 从厂商控制台确认公网 IPv4 没变。

重装会删除 VPS 上原有数据。不要在没有备份时操作生产机。

### 7.2 云防火墙/安全组

有些厂商在 Linux UFW 之外还有一层 Security Group / Cloud Firewall。至少允许：

| 端口 | 协议 | 来源 | 用途 |
|---:|---|---|---|
| SSH 端口，默认 22 | TCP | 优先仅自己的公网 IP；不方便时临时放宽 | 远程管理 |
| 80 | TCP | 0.0.0.0/0 | HTTP 和 Let’s Encrypt challenge |
| 443 | TCP | 0.0.0.0/0 | 节点和 HTTPS |
| 24443 | TCP | 程序会尽量仅允许当前 SSH 来源 | 安装阶段临时真机验货 |

24443 不是常驻公网端口。程序完成提升或中止后应关闭对应临时规则。不要手工长期全网开放 3x-ui 面板端口；面板通过 127.0.0.1 SSH 隧道访问。

### 7.3 从 Windows 测试 SSH

~~~powershell
$VpsIp = "203.0.113.10"
Test-NetConnection $VpsIp -Port 22
~~~

TcpTestSucceeded 应为 True。若为 False：

- VPS 可能还在重装；
- SSH 端口不是 22；
- 云防火墙没放行；
- sshd 没启动；
- 当前网络或安全软件拦截了连接；
- IP 填错。

不要为了“先跑起来”关闭所有防火墙。

---

## 8. 下载并启动 ProxyNodeAssistant

### 8.1 选择正确版本

Windows：

~~~text
ProxyNodeAssistant-v0.9.5-win64.exe      绝大多数 Intel/AMD Windows 电脑
ProxyNodeAssistant-v0.9.5-win32.exe      仅 32 位 Windows 10
ProxyNodeAssistant-v0.9.5-win-arm64.exe  Windows on ARM
~~~

Android 使用 v0.9.5 universal APK。Android 执行远端操作前，应暂停会把 SSH 也绕回目标 VPS 的全局 VPN，避免连接自环。

### 8.2 校验下载文件

在发布目录下载 SHA256SUMS-v0.9.5.txt，然后在 PowerShell 执行：

~~~powershell
Get-FileHash -Algorithm SHA256 .\ProxyNodeAssistant-v0.9.5-win64.exe
~~~

把结果和校验清单对应行逐字符比较。哈希不一致不要运行，重新从正式发布页下载。

### 8.3 OpenSSH 检查

Windows EXE 启动时会检查 ssh.exe、scp.exe、ssh-keygen.exe 和 ssh-keyscan.exe：

- 已安装且可启动：显示 GOOD 后直接进入界面；
- 未安装：只申请一次管理员权限，安装后验证；
- 安装或验证失败：明确停止，不进入安装死循环。

不需要提前下载来历不明的 SSH 工具。

---

## 9. 第一次安装：逐屏怎么选

### 9.1 选择唯一安装入口

在首页点击：

~~~text
[1] 安装 / 升级 / 自适应优化
~~~

只有这一项能上传和安装远端内嵌包。其他远端功能不会偷偷重装。

### 9.2 选择 SSH 登录方式

新 VPS、自用电脑推荐：

~~~text
[2] 节点专属长期 key
~~~

如果本机还没有这台 VPS 的 key，程序会先让你输入一次 VPS 密码，验证成功后再明确询问是否绑定。选择绑定后，以后维护可以直接使用这台节点专属 key。

朋友临时帮忙或公共电脑推荐：

~~~text
[1] 临时密码
~~~

该模式的一次性公钥会在本项结束时从 VPS 撤销，本机临时私钥也会删除。

### 9.3 填写连接信息

~~~text
VPS IP 或主机名：填写 VPS 公网 IPv4
SSH 用户名：通常是 root；部分厂商是 ubuntu 或 debian
SSH 端口：没改过就填 22
~~~

程序会显示 VPS 的 SSH Host Key 指纹。最好和厂商控制台展示的指纹核对；至少确认 IP、端口和刚才重装的服务器完全一致，再点“是/Y”保存。

Host Key 不是登录私钥。它用于确认“你连接的是哪台服务器”。如果未来无缘无故变化，程序会失败关闭，不应盲目接受。

### 9.4 输入第一次密码

密码框只显示圆点。输入厂商给的当前密码后提交：

- 密码区分大小写；
- 粘贴时程序会清理常见结尾换行，但仍应确认没有多余空格；
- 某些厂商禁用 root 密码登录，用户名可能应为 ubuntu；
- 连续失败不要反复撞库，去厂商 Console/Root password reset 重置。

密码验证成功后，如果选择长期 key，程序询问是否绑定。自己的固定电脑通常选 Yes；借用电脑选 No。

长期私钥显示后必须立即保存到密码管理器或加密存储。不要截图发群，不要保存到公开网盘。

### 9.5 输入域名和邮箱

~~~text
Cover 域名：cover.example.com
Let’s Encrypt 邮箱：你真实可收信的邮箱
~~~

不要输入：

- https://cover.example.com
- cover.example.com/
- 203.0.113.10
- Cloudflare 账号密码
- 一个不存在的邮箱

程序会检查 A 记录是否指向当前 VPS；检查失败就回到第 5—6 章排查，不要强行继续。

### 9.6 施工中的建议选择

- 自适应性能档：新机可采用推荐自动档，之后可用菜单 16 回滚；
- 3x-ui 凭据：让程序生成随机值，并保存完整交接单；
- 伪装站：R 为随机，A 为按域名稳定选择，1—15 为指定模板；
- WARP/OpenAI 路由：按实际需求选择，不需要就跳过；
- 已有同版：程序跳过重复上传/bootstrap，只继续幂等检查；
- 远端旧版：由 [1] 升级；
- 远端版本比 EXE 新：不要降级，换新版客户端。

### 9.7 24443 真机验货

当远端还没有可用的 443 VLESS+REALITY 时，程序会先创建一个 24443 shadow，并打印临时 vless:// 链接。

必须：

1. 复制这条 24443 链接；
2. 导入 v2rayN 或其他兼容客户端；
3. 选择该节点；
4. 真正打开网页测试，而不是只看客户端显示；
5. 确认可以浏览后才回答 Yes；
6. 如果不能用，回答 No，让程序停止提升，随后运行菜单 [3] 诊断。

绝不能为了让进度继续而谎报 Yes。这个确认决定是否把经过实测的 shadow 提升到正式 443。

### 9.8 凭据交接、备份和面板

成功后程序显示经过完整性校验的 Credential Handoff。最上方必须明确包含 `VPS_ACCOUNT`、`VPS_PASSWORD`、`PANEL_ACCOUNT`、`PANEL_PASSWORD` 四项；缺少任何一项都不算完成，也不会允许复制。随后还包含：

- 3x-ui 本地隧道访问地址；
- panel 用户名、密码和 API Token；
- UUID、REALITY 公钥/shortId；
- vless:// 链接；
- 订阅地址；
- SSH key 保存位置。

按顺序做：

1. 点复制；
2. 立即粘贴到密码管理器；
3. 确认保存完整；
4. 接受默认选项清空剪贴板；
5. 是否清理远端多余备份：新机可选 No，已有多次施工的机子可明确选 Yes；
6. 是否打开面板：需要就选 Yes。

面板通过 127.0.0.1 SSH 隧道打开，不暴露公网端口。浏览器加载完页面后，程序仍必须保持运行；用完点击“关闭面板隧道”，等界面确认关闭后再退出。

---

## 10. 导入订阅并做最终验收

### 10.1 导入

交接单里的订阅 URL 和 vless:// 链接都属于秘密。以 v2rayN 为例：

1. 复制订阅 URL；
2. 在订阅分组中新增订阅；
3. 更新订阅；
4. 选择生成的节点；
5. 测试 TCPing/真连接；
6. 启用代理；
7. 打开几个正常 HTTPS 网站实际浏览。

不要把订阅 URL 发到公开测速网站。拿到 URL 的人可能能获取节点配置。

### 10.2 验收清单

- [ ] Cloudflare 域名状态是 Active；
- [ ] cover A 记录是灰云 DNS only；
- [ ] 1.1.1.1 查询到 VPS IPv4；
- [ ] SSH 可以登录；
- [ ] 程序 [1] 最终成功；
- [ ] 24443 或正式 443 已真实浏览验证；
- [ ] 80/443 服务正常；
- [ ] Nginx 配置测试通过；
- [ ] x-ui、nginx、fail2ban 等状态正常；
- [ ] 订阅能更新；
- [ ] 客户端真实浏览正常；
- [ ] 面板只能通过 127.0.0.1 隧道访问；
- [ ] 交接单已保存；
- [ ] SSH 私钥有安全备份；
- [ ] Windows 剪贴板已清空；
- [ ] 厂商续费日、域名续费日和流量重置日已记录。

最后运行菜单 [3]“自动体检与排障”。如果需要向维护者求助，用菜单 [10] 生成紧急诊断报告，发送前仍要人工检查并脱敏。

---

## 11. 常见错误怎么处理

### 11.1 DNS 没指向这台 VPS

检查：

- Cloudflare 是否 Active；
- A 记录 Name 是否写成 cover；
- Content 是否为正确 IPv4；
- 是否有冲突 AAAA/CNAME；
- 是否是灰云；
- 公共 DNS 是否已更新。

~~~powershell
Resolve-DnsName cover.example.com -Type A -Server 1.1.1.1
Resolve-DnsName cover.example.com -Type A -Server 8.8.8.8
~~~

### 11.2 Cloudflare 一直 Pending

- 去注册商查看 Nameserver，而不是只看 Cloudflare DNS Records；
- 两条 Nameserver 是否逐字正确；
- 是否仍混着旧 Nameserver；
- 换 NS 前是否关闭旧 DNSSEC；
- 等待最长 24 小时；
- 用 nslookup -type=ns 检查公共结果。

### 11.3 ACME/证书公网预检 403 或 404

优先检查：

- A 记录是不是橙云；必须改灰云；
- 80/tcp 是否在云防火墙和 UFW 都放行；
- 域名是否解析到当前 VPS；
- 是否存在手工安装的另一个 Nginx server block；
- VPS 上是否有旧控制面板抢占 80/443；
- DNS 是否仍缓存旧服务器。

修好后重新运行 [1]。不要绕过公网 challenge 预检。

### 11.4 SSH 密码一直被拒绝

- 确认用户名是 root、ubuntu 还是 debian；
- 确认密码没有多余字符，且大小写正确；
- 厂商邮件中的密码可能已被你后来重置；
- 某些系统默认禁止 root 密码登录，应使用厂商给的普通用户；
- 去厂商 Web Console 登录或重置 Root Password；
- 检查 sshd 和云防火墙；
- Android 上先暂停可能造成自环的全局 VPN。

程序不会为了修 SSH 而静默改 VPS 密码。密码轮换必须由你明确选择对应功能，并会显示新密码。

### 11.5 443 被未知服务占用

不要让脚本强行覆盖。先运行 [3] 诊断，确认占用进程。若是反复安装留下的测试机，备份后重装干净 OS 通常最省时间；若是生产机，先查清依赖再迁移端口。

### 11.6 订阅导入后延迟为 -1

- 先确认域名仍是灰云；
- 确认客户端系统时间准确；
- 用 [3] 检查 443、Xray、Nginx 和订阅；
- 确认导入的是最新交接单，不是升级前旧链接；
- 确认客户端支持对应 VLESS+REALITY 参数；
- 确认云防火墙允许 443/tcp；
- 不要只看延迟数字，尝试真实连接并看客户端日志。

### 11.7 面板打开后白屏

- 不要在浏览器刚打开时退出 ProxyNodeAssistant；
- 等 HTML、JS、CSS 全部通过 SSH 隧道加载；
- 地址必须是程序给出的 127.0.0.1 隧道地址；
- 本地端口冲突时重新执行 [2]；
- 用完点“关闭面板隧道”，不要直接杀进程。

### 11.8 Host Key 发生变化

如果刚刚在厂商后台重装 VPS，Host Key 改变可能是正常的；先从厂商控制台核对新指纹，再按程序的 key/历史管理流程更新。没有重装却突然变化时先停止，排查 IP 是否回收、DNS 是否改错或是否存在中间人风险。

---

## 12. 部署后的日常维护

### 每周或出现问题时

- [3] 自动体检与排障；
- [17] SSH/vnStat 流量估算；
- 查看 VPS 厂商精确流量和账单；
- 检查域名、证书和订阅可达性。

### 改配置前

- [15] 清理远端多余备份并只保留当前配置备份；
- 重大变更用 [9] 完整灾备；
- 厂商后台再做一份快照。

### 密钥管理

- 长期 key 按 VPS + 用户分别保存；
- Windows 绑定目录在 %USERPROFILE%\.ssh\proxy-runbook\；
- 可恢复归档在 %USERPROFILE%\.ssh\proxy-runbook-revoked\；
- 不需要当前绑定位置时，可用 key 管理把全部 key 转入备份态；
- 恢复时从程序 key 管理入口选择备份，不要手工随意改文件名；
- 私钥泄露后必须重新生成、验证新 key，再撤销旧公钥。

### 到期和流量

- 给 VPS、域名各设置至少 7 天和 30 天两个提醒；
- 自动续费不是备份，余额不足仍可能停机；
- 以厂商后台的计费流量为准，vnStat 只是服务器视角估算；
- v0.9.5 的服务商 API Key/Token 只能临时输入，或经确认存进系统安全存储，不能写进教程、日志或仓库。

---

## 13. 一页打印版检查表

### 购买前

- [ ] KVM VPS
- [ ] 独立公网 IPv4
- [ ] Ubuntu/Debian
- [ ] 1 GB 内存以上
- [ ] 10 GB 磁盘以上
- [ ] 可 sudo/root
- [ ] 可重装、重置密码、Console 救援
- [ ] 22/80/443 可用
- [ ] 已看续费价、流量和退款规则

### 域名

- [ ] 域名由自己账号持有
- [ ] 可修改 Nameserver
- [ ] 已开启 2FA
- [ ] 已记录续费日和续费价
- [ ] Cloudflare 已添加根域名
- [ ] 换 NS 前旧 DNSSEC 已关闭
- [ ] Cloudflare 状态 Active
- [ ] Active 后按需重新开启 DNSSEC

### DNS

- [ ] A 记录 cover → VPS IPv4
- [ ] 灰云 DNS only
- [ ] 无冲突 AAAA/CNAME
- [ ] 1.1.1.1 和 8.8.8.8 查询正确

### VPS

- [ ] 干净 Ubuntu 22.04/Debian 12
- [ ] SSH 用户和端口正确
- [ ] 初始密码已存密码管理器
- [ ] 云防火墙允许 SSH、80、443
- [ ] Windows Test-NetConnection SSH 成功

### 部署

- [ ] 下载文件 SHA-256 正确
- [ ] 使用 [1] 唯一安装入口
- [ ] Host Key 已核对
- [ ] 已决定临时模式或长期 key
- [ ] 域名和邮箱本人输入
- [ ] 24443 已真实浏览后才确认
- [ ] 交接单和私钥已安全保存
- [ ] 剪贴板已清空
- [ ] 订阅已导入并真实浏览
- [ ] [3] 自动体检通过

---

## 14. 资料入口

- [ProxyNodeAssistant 完整使用说明书](ProxyNodeAssistant-v0.9.5-完整使用说明书.md)
- [ProxyNodeAssistant Android 使用说明](ANDROID.md)
- [Cloudflare Dashboard](https://dash.cloudflare.com/)
- [Cloudflare 完整 DNS 接入](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/)
- [Cloudflare DNS 记录管理](https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/)
- [Cloudflare 网络端口说明](https://developers.cloudflare.com/fundamentals/reference/network-ports/)
- [VPSDeck VPS 选购参考](https://vpsdeck.com/cheap-cost-effective-vps/)

支付方式和厂商库存属于高频变化信息。发布或转发本教程时，请保留“核对日期”和官方链接；真正付款前，再在官方帮助中心和结账页复核一次。
