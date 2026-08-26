# TextNodeAssistant v0.9.5 更新说明

v0.9.5 是正式版前的冻结版本号。本次是产品基线重构，不只是改名：Windows、Android 和 Linux 工具包统一为 TextNodeAssistant（TNA），同时保留对旧本地/远端状态的只读迁移兼容。

## 本次维护补丁：新设备邀请输入门禁

- 图形客户端的 `J / 新设备加入已有节点` 不再显示或发送标准 VPS 连接表；邀请本身携带节点端点，启动时不会把登录方式、主机、用户、端口等残留输入误当成邀请。
- 未粘贴邀请时，提交按钮会保持在当前提示并明确显示“此项必须填写”，不会把空行送给后端，也不会再出现 `invalid device invitation prefix` 的假性即时失败。
- 后端同时使用必填输入保护；只有收到 `TNAINV2.`（兼容旧 `PNAINV1.`）后才进入解析和首次设备绑定流程。

## 产品与界面

- 外层改为轻量私人网盘客户端，普通账号和 admin 均可登录；
- 高级图形控制台保留全部原有施工能力，默认由本机 admin 二次门禁保护；
- 本机 admin 提供系统保护存储、加盐验证器、加密恢复包和恢复码；
- 新机如实显示“未挂载节点”，引导进入高级控制台或无需预登录的设备邀请入口；
- Windows x64/x86/ARM64 和 Android 原生客户端共用同一协议与工具包；
- 操作、秘密输入、确认、日志、隧道启停全部在图形界面完成。

## 唯一施工入口与事务

- `[1]` 是上传/升级工具包、安装网盘、恢复组件和改变拓扑的唯一入口；
- 同版本同构建跳过重复上传与 bootstrap；旧版本先备份后升级；远端构建更新时拒绝降级并提示更新客户端；
- 施工使用持久事务日志、阶段状态、回滚回执与真实探针；
- 退出码、结构化成功标记、元数据回读和功能探针缺一不可；
- 失败不再复制空交接单、不猜 panel 端口、不自动打开白屏页面；
- 已拆除或部分缺失的节点由 `[1]` 识别现场并恢复缺失部分。

## 三种线路拓扑

- `[1]` 必须明确选择仅灰云、仅橙云或双路；空输入无效；
- `[0]` 保持只对已经完整施工的受管节点显示；
- 灰云使用 DNS-only 子域名和 REALITY 直连；
- 橙云使用 Proxied 子域名、Cloudflare Edge :8443 和回环 XHTTP；不依赖免费计划不可用的 Origin Rule 端口改写；
- 双路使用两个不同子域名和两条独立订阅；
- 三模式互切复用同一事务协调器，先准备、验证再提交，不留半条链路；
- `[22]` 降为只读拓扑状态与指导，不允许绕开 `[1]` 施工；
- Windows TUN/VPN 劫持 DNS 时给出明确诊断，不把本地解析故障误判为远端错误。

## Cloudflare 橙云验收

### r28：修复 XHTTP 新建入站的 jq 域名变量错误

上一版在新建回环 XHTTP 入站时引用了 `$domain`，但没有把 Bash 变量绑定为 jq 参数，导致 `jq: error: $domain is not defined`，操作在“回环 XHTTP 创建”阶段中止。r28 增加显式 `--arg domain "$domain"` 绑定，并加入静态回归测试；产品版本号仍为 v0.9.5。

### r27：先准备源站 8443，再做公网证书预检

旧构建在既有 Cloudflare Origin Rule 将请求改写到源站 `:8443` 时，会先做 HTTP-01 公网预检；但公网 `8443` 尚未被程序建立监听，导致 Cloudflare 连接超时，后续的防火墙和 Nginx 阶段根本不会执行。r27 已把顺序改为：先校验并取得 Cloudflare 官方 CIDR，使用 UFW 仅允许 Cloudflare 访问，建立只服务 ACME challenge 的临时明文公网 `8443`，确认监听后才进行 HTTP-01 预检和 Certbot。证书成功后临时 vhost 自动清理，Cloudflare 限定规则保留并由正式 TLS/XHTTP vhost 接管；任一失败都会回滚本次临时监听和新增规则，不会留下裸露端口。

因此首次切换橙云不再要求用户手动预先开放 `8443`。正式 Origin Rule 仍建议只对 HTTPS 请求改写到源站 `8443`，HTTP 请求保留到源站 `80`，以免普通 HTTP 重定向被错误送到 TLS 端口。

### 橙云 DNS 检测误报修复

旧构建在橙云前置步骤只等待 Cloudflare 与 Google 两个 DoH 地址；部分网络、VPN/TUN 或安全软件会拦截到 `1.1.1.1/8.8.8.8` 的 HTTPS 请求，导致系统 DNS 明明已经解析成功却被误报为超时。当前构建并发读取系统解析和两个公共解析器，任一解析器返回 IPv4 即允许进入下一步，并明确显示 `system/cloudflare/google` 各自状态。此处只代表 DNS 已有答案，后续 Cloudflare 边缘探测、源站回读和真实客户端浏览仍是强制门禁，不会因本地 DNS 兜底而伪造橙云成功。

### XHTTP 导出端点修复（本次维护补丁）

本次又补上了面板单节点分享和订阅的实际兼容层：3x-ui 的回环 XHTTP 入站本身必须保持 `security=none`，但橙云客户端入口必须使用公网 TLS。若只写 `forceTls=same`，3x-ui 的入站详情分享器会继承回环的 `none`，产生 `security=none`、空 SNI/Host 甚至回环端口的错误链接；这正是“面板复制出来、客户端 `read/write on closed pipe`”的根因。

现在受管入站会同时写入并回读：

- `externalProxy.forceTls=tls`、公网橙云域名和 Edge `:8443`；
- `tna-cdn-xhttp` HostGroup（公网 hostname、SNI、Host header、XHTTP path、`chrome` fingerprint）；
- 本机 `/sub/` 订阅适配器（仅监听 localhost），只修正 XHTTP 的 TLS、SNI、Host、路径和公网端口，Reality/灰云节点保持原样。

旧客户端中已经导入的配置和旧面板链接都是不可变快照，不会自动改变；请在 3x-ui 刷新页面后，从“入站详情/分享”重新复制，或重新更新受管 `/sub/` 订阅。运行门禁会在 externalProxy/HostGroup 任一项无法回读时失败，不生成看似成功的链接。适配器访问日志关闭，不记录订阅 ID 或链接内容。

- XHTTP 入站继续只监听 `127.0.0.1` 的内部端口；
- 受管入站现在显式写入 `externalProxy.forceTls=tls` 与 HostGroup，让 3x-ui 入站详情/订阅导出的节点使用橙云域名的 8443，而不是回落到 `cover:<loopback-port>`；
- 已存在的旧标记 `pna-cdn-xhttp` 只做兼容识别，不会重复创建入站；生成链接、重定向和重新施工时会幂等修复该字段；
- 外部代理字段回读失败会中止并回滚本地状态，避免生成看似成功但客户端延迟为 `-1` 的链接。

### 源站证书公网预检诊断

- 既有节点切换到新的橙云 hostname 时，证书助手会临时创建仅匹配该 hostname 的 ACME HTTP vhost；不会覆盖现有 Nginx 配置，退出时自动清理并 reload；
- 证书助手先用目标 Host 头直连 VPS 的 `127.0.0.1:80` 做本机预检，再做公网预检；任一阶段失败都会保留 HTTP 状态码和分类提示。公网阶段还会区分重定向、401/403 拦截、404 未命中 vhost，以及 000/5xx 的 80 端口/源站不可达，便于按提示修 Nginx 或 Cloudflare 规则；
- 如果公网响应为 `400` 且回显 `X-TNA-Origin-Port: 8443`，会明确标记 `CLOUDFLARE_HTTP_ORIGIN_RULE_MISROUTED`：这表示 Cloudflare 把 HTTP-01 请求也改写到了 TLS 8443。Origin Rule 必须只匹配 HTTPS；HTTP 80 要保留到源站 80（或临时切灰云）才能签发证书。HTTPS/8443 正常不代表 HTTP-01 路径可用。
- 特别注意：免费计划的推荐路径是直接访问 Cloudflare Edge `:8443`，不需要“目标端口改写” Origin Rule。旧版本留下的“hostname =/contains … → 8443”规则必须删除；把通配符改成“等于”只改变匹配范围，并不会解除 HTTP-01 的 80→8443 死锁。若暂时保留规则，至少必须限制为 HTTPS，且 HTTP `:80` 仍要回源到源站 `:80`。
- 公网状态为 `000` 超时且源站只有回环 `127.0.0.1:8443` 时，程序现在会明确提示上述规则/端口死锁，不会把它误报为 VPS 密码、证书或 Nginx 本机故障。
- 临时 vhost 文件名使用域名 SHA-256，不受超长域名影响；证书签发仍要求公网 HTTP-01 真正返回探针内容，未通过不会调用 Certbot，也不会提交 CDN 生产链路。

- 引导逐项确认 Proxied、Universal SSL、Full (strict)、8443 端口、Cache Bypass 和无额外拦截规则；
- 输入 `q` 可在任一步安全取消；
- 自动准备和验证源站证书；
- 公网 8443 只允许 Cloudflare 官方 CIDR；
- 同时验证 `Cf-Ray`、受管源站标记、源站端口覆盖和外部直连拒绝；
- 真机 8443 XHTTP 浏览成功后才提交生产状态。

## 强制网盘

- 网盘成为完整施工的必选组件；
- copyparty 固定供应链版本、大小和 SHA-256，非 root 运行；
- 每台节点随机使用 `39000—39999` 的回环端口，不需要域名，不开放公网端口；
- 每 VPS 最多 2 个普通网盘账号，只有完整施工且当前设备受信后才允许注册；
- 普通账号可在该 VPS 的所有受信设备访问同一空间；
- 普通账号可在外层用旧密码二次确认新密码改密，admin 必须进内层改；
- 切换网盘 VPS 会退回登录页并要求目标节点账密；
- admin 恢复能力按 NODE_ID 隔离并保存到系统安全存储。

## r23 远端网盘认证修复

- 修复安装/升级网盘时自检返回 401 的问题：配置渲染循环不再覆盖安装函数中的用户名、配额和空间变量；
- 安装结果现在会保留真实的 admin 用户名和自适应配额，并使用同一组凭据完成列表、上传、下载和删除 CRUD 验证；
- 失败仍按事务回滚，远端不会留下半套网盘配置；本次内部构建号为 `20260827-v095-tna-cdn-acme-origin-8443-r28`，产品版本号仍焊死为 v0.9.5。

## 设备准入与 SSH

- controller 创建的邀请在新设备首次真实绑定成功后才消费，审批或网络中断可重试；
- 新设备可从未登录首页响应邀请，无需预先进入 VPS 菜单；
- 每设备使用独享 SSH key 和 VLESS 身份，可分别暂停、恢复和吊销；
- 最后一个 controller 受保护；
- Host Key 采用固定与人工核对，算法兼容探测不再因单个 KEX 不受支持而错误失败；
- 临时密码仅进入受保护输入通道，不进入命令行参数和普通日志；
- 厂商 VNC/Console 始终作为严格模式的救援兜底。

## 拆除施工和恢复基线

- `[18]` 固定为“拆除施工和恢复基线”；
- 危险动作前生成、下载、校验救援包；
- 可仅拆代理并保留强制网盘；
- 可整体拆除并恢复可信原生基线；
- 只有代理已拆除时才显示单独拆除剩余网盘；
- 旧节点无可信基线时标记 `LEGACY_UNCERTAIN`，不虚构完全还原；
- 重新安装或恢复仍只使用 `[1]`。

## 凭据、恢复与隐私

- 完整交接单必须如实包含 VPS 登录标识、面板真实可验证账号密码、端口、WebBasePath、设备节点和网盘信息；
- 旧密码不可从哈希恢复时明确标记未知并要求主动轮换；
- 本机 admin、网盘 admin 能力和节点 key 使用 Windows Credential Manager/DPAPI 或 Android Keystore；
- 普通账号恢复秘密使用 controller 加密信封；
- 发布包不内置真实 VPS、域名、邮箱、密码、Token、私钥、订阅或交接单；
- 发布门禁扫描源码、EXE、APK、ZIP、TAR 与解包内容，并生成 SHA-256 与 SPDX SBOM。

## 发布文件

```text
TextNodeAssistant-v0.9.5-win64.exe
TextNodeAssistant-v0.9.5-win32.exe
TextNodeAssistant-v0.9.5-win-arm64.exe
TextNodeAssistant-v0.9.5-android-universal.apk
TextNodeAssistant-v0.9.5-portable.zip
TextNodeAssistant-v0.9.5-source.zip
text-node-assistant-toolkit-v0.9.5.tar.gz
TextNodeAssistant-v0.9.5-sbom.spdx.json
SHA256SUMS-v0.9.5.txt
```

旧应用 ID、旧 Android 签名身份和旧状态目录只作为原地升级兼容层存在，不是新产品公开名称，也不会把旧运行态秘密写入成品。
### r29：兼容旧版 PNA 设备身份，修复首个 controller 初始化失败

部分已经使用早期 v0.8.x/PNA 构建的本机，其设备身份仍是 `pna-ed25519:*`。此前 v0.9.5 的远端设备准入脚本虽然读取状态时兼容 `pna-*`，但在首个 controller 注册、签名校验和绑定校验处只接受 `tna-*`，导致已有本机在 `[1]` 完成施工后报 `TNA_DEVICE_ERROR=PUBLIC_KEY_INVALID`。r29 统一兼容 `tna-*` 与 `pna-*` 身份，并按公钥前缀推导相同前缀的设备 ID；产品版本号仍为 v0.9.5。
