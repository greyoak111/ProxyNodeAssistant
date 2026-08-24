# Proxy Runbook v0.6 — Technical Basis

> 目标：只保留当前公开技术依据，不保留任何某个用户/节点的历史施工记录。

## 1. Windows OpenSSH

Windows OpenSSH Client 提供：

```text
ssh
scp
ssh-keygen
ssh-keyscan
```

v0.6 用法：

```text
ssh-keyscan → 只展示 VPS SSH host PUBLIC-key fingerprint
ssh-keygen  → Windows 本地生成每节点 Ed25519 client keypair
ssh         → 初始登录、公钥安装、远端执行
scp         → 上传工具包
```

SSH client Private Key：

```text
只存在当前 Windows 用户的 %USERPROFILE%\.ssh\proxy-runbook\...
```

VPS host private keys：

```text
永不导出，只显示 public-key fingerprint
```

---

## 2. 3x-ui unattended install

当前官方 installer 支持：

```bash
XUI_NONINTERACTIVE=1 bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

未显式指定时，脚本安装会为每个实例随机生成：

```text
XUI_USERNAME
XUI_PASSWORD
XUI_PANEL_PORT
XUI_WEB_BASE_PATH
XUI_API_TOKEN
```

完整结果写到 root-only：

```text
/etc/x-ui/install-result.env
```

v0.6 **故意不预设这些值**。

随后只收敛：

```text
listenIP = 127.0.0.1
```

panel port 保留该节点自己的随机/现有端口。

---

## 3. 3x-ui API

v0.6 使用当前正式接口，不直接改 SQLite：

```text
GET  /panel/api/server/getNewUUID
GET  /panel/api/server/getNewX25519Cert

GET  /panel/api/inbounds/list
POST /panel/api/inbounds/add
POST /panel/api/inbounds/update/{id}
POST /panel/api/inbounds/del/{id}

POST /panel/api/xray/
POST /panel/api/xray/update
POST /panel/api/xray/testOutbounds
POST /panel/api/server/restartXrayService
```

用途：

```text
自动生成 UUID / X25519
创建 24443 Reality shadow
shadow 验证后 promote
已有 443 的安全 clone / A-B / commit
持久写入 WARP outbound + OpenAI routing
```

---

## 4. REALITY

服务端核心目标：

```text
network = tcp
security = reality
target = 127.0.0.1:8443
serverNames = [用户亲自输入的 cover domain]
```

凭据：

```text
UUID
PrivateKey
PublicKey
shortId
subId
```

v0.6 自动生成后在 Credential Handoff **全文显示真实值**。

PrivateKey 只属于服务端；客户端只使用 PublicKey 等客户端字段。

生产 443 的改变必须：

```text
24443 shadow
→ 真人客户端验证
→ 用户明确确认
→ 才 commit 到 443
```

---

## 5. Nginx + Let's Encrypt

cover domain 和 Let's Encrypt email：

```text
只能由操作者手工输入
没有共享包默认值
不根据 IP 自动猜
```

Nginx TLS target：

```text
127.0.0.1:8443
```

公网不开放 8443。

证书通过 Certbot webroot 获取；续期 deploy hook 在证书更新后先 `nginx -t` 再 reload。

---

## 6. Cloudflare WARP

当前 Linux WARP CLI 基本流程：

```text
warp-cli registration new
warp-cli tunnel protocol set MASQUE
warp-cli mode proxy
warp-cli connect
```

Local Proxy：

```text
localhost
默认/本手册标准端口 40000
SOCKS5
```

当前 Proxy mode 使用 MASQUE；Xray `warp-masque` outbound 指向：

```text
127.0.0.1:40000
```

OpenAI/ChatGPT 规则持久写进 Xray template；其它流量保持 VPS direct。

---

## 7. Cloudflare DNS API（可选）

只有用户主动选择时调用。

用户必须先亲自输入 cover domain；脚本不生成域名。

Token：

```text
只在本次 shell 使用
不写共享包
不写 runtime node metadata
不放进 curl argv
```

记录创建为：

```json
{
  "type": "A",
  "name": "<用户输入域名>",
  "content": "<当前 VPS IP>",
  "proxied": false,
  "ttl": 1
}
```

即 DNS only。

---

## 8. “最优”含义

v0.6 不做玄学调参。

自动收敛只包含可验证项目：

```text
必要公网端口
UFW
fail2ban
内核明确支持时 fq+BBR
panel localhost-only
随机/现有 panel port
长随机 WebBasePath
Nginx localhost TLS target
WARP MASQUE Local Proxy
持久 OpenAI routing
备份 / Doctor / credential handoff
```

明确禁止自动：

```text
apt full-upgrade
发行版升级
VPS reboot
直接覆盖已有生产 443
自动关闭 SSH 密码入口
自动升级 3x-ui/Xray
删除未知 iptables/nftables/DOCKER-USER 规则
```

---

## 9. v0.9.5 CDN/XHTTP 与 copyparty 技术边界

v0.9.5 默认仍由 Xray REALITY 持有源站公网 443。CDN 路径使用 3x-ui API 创建 VLESS + XHTTP `packet-up`，`listen=127.0.0.1`、无 XHTTP 内层 TLS，由本工具回读完整入站后自行生成链接；不采用面板分享链接。Nginx 先绑定 `127.0.0.2:8443`，通过本地验收后才可在 UFW 已限制为 Cloudflare 官方 CIDR的前提下绑定“VPS 的明确公网 IPv4:8443 + `127.0.0.2:8443`”。这里有意拒绝 `0.0.0.0:8443`，避免与既有 `127.0.0.1:8443` 伪装后端发生监听冲突。Cloudflare 边缘接收 hostname:443，并由人工 Origin Rule把目标端口覆盖为 8443；所以源站 Reality 443不需要让位。

Cloudflare API状态不由程序修改或读取，用户在官方 Dashboard人工设置橙云、`Full (strict)`、Origin Rule与 Cache Bypass。生产链接门禁同时要求：DNS全部落在官方 Cloudflare CIDR且不含源站 IP，边缘返回 `Cf-Ray` 与受管 8443标记，外部设备无法直连源站 8443，VPS本地入站/证书/listener/UFW回读一致，最后真实客户端浏览并显式确认。撤回会先恢复回环 listener，再只删除带 ownership marker的 UFW规则；Reality 443和SSH策略保持不变。

Cloudflare CIDR 下载使用 HTTPS、数量/地址族/重复项校验和本地 SHA-256 记录，但本构建只生成规则计划，不写入 UFW。没有 `CLOUDFLARE_FIREWALL_APPLIED=1` 时，公网 Nginx staging 路径会拒绝启动。生产 443 候选只能写到 root-only 文件，不能启用。

copyparty 固定 v1.20.21 SFX、文件大小和 SHA-256，使用非 root systemd 用户、只读系统保护和精确可写目录。HTTP 后端只监听 `127.0.0.1:3923`，关闭额外协议、内建 TLS、zeroconf 与可执行 HTML/Markdown。账户只保存 scrypt 哈希；明文通过 stdin 进入哈希/CRUD事务。`u2sz:1,64,64`、`vmaxb`、`vmaxn` 与 `df` 共同限制分块、容量、文件数和最低可用空间。
