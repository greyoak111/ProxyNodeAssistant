# Proxy Node Assistant / Runbook v0.9.5

> v0.9.5 新增可回滚的硬件自适应性能档、vnStat 流量计数、回环 CDN/XHTTP 实验阶段和固定供应链的 copyparty 私人网盘。默认生产模式仍为 REALITY 直连；橙云与公网 443 切换尚未开放。详见 `CHANGELOG-v0.9.5.md`。

Windows EXE 在主菜单前一次性检查/安装并验证 OpenSSH；菜单 `[14]` 可在不登录 VPS 的情况下配置、撤销或查看当前用户的本地 `127.0.0.1:10808` 代理环境变量。

菜单 `[16]` 检测并应用 auto/low/standard/high 性能档，所有受管改动都先备份并支持回滚。菜单 `[17]` 使用 vnStat 提供 VPS 侧流量估算；菜单 `[18]` 先把救援包下载并校验到 Windows，再恢复施工前基线或执行旧节点有界全拆。服务商精确计费口径由 Windows EXE 的本地 `[T]` 流量中心查询。

菜单 `[15]` 通过标准临时密码/长期 key 二级登录，在新当前配置包完整验证后清理严格限定名称的旧管理备份，并确保最终只保留一份 root-only 当前配置压缩包。

## 最推荐的交付物

Windows x64 用户优先只用：

```text
ProxyNodeAssistant-v0.9.5-win64.exe
```

这是一个**单 EXE 双语引导器**。工具包 TAR 已直接嵌入 EXE，本身不需要旁边再放几十个脚本。

共享 EXE / ZIP 中仍然遵守：

```text
零真实 VPS IP
零真实域名
零真实账号
零真实密码
零真实 SSH/REALITY Private Key
```

每项远端操作都重新确认目标与登录方式；可选历史只保存节点 IP/主机名、SSH 用户和端口，可随时单条删除或清空，不保存密码、域名、邮箱或 key。

---

# EXE 菜单

支持中文 / English 一键切换：

```text
1  【唯一安装入口】识别版本：同版跳过 / 旧版升级 / 自适应优化
2  无感打开 3x-ui 面板
3  自动体检与排障
4  安全自动修复
5  随机化 VPS 登录密码
6  随机化 3x-ui 账号密码
7  显示/复制凭据交接单
8  优化前台伪装网站 + Nginx
9  节点备份
10 紧急诊断报告
11 重新生成 SSH 登录密钥
12 清空剪贴板
13 卸载远端内嵌包（保留节点数据与灾备）
14 本地 10808 代理：配置 / 撤销 / 查看
15 清理远端多余备份 + 仅备份当前配置
16 自适应性能档：检测 / 自动 / 低配 / 标准 / 高配 / 回滚
17 SSH/vnStat 流量估算与 70/85/95% 预警
18 全量拆除受管施工 / 恢复原始基线（先下载救援包，保留 SSH）
21 私人网盘（固定 copyparty、回环/SSH 隧道、账密 CRUD、默认保留文件）
22 Experimental CDN/XHTTP（仅回环影子与 Cloudflare 只读计划）
T  服务商流量中心（纯本地；秘密可选存入 Credential Manager）
K  管理已绑定 key：换 VPS / 远端撤销 + 本机可恢复备份
H  管理 VPS 登录历史
L  中英切换
C  清空当前选择和隧道（不删除绑定）
```

除 `[12]`、`[14]`、`[T]`、`[H]`、语言和退出等纯本机项目外，每个远端项目都会先重新选择临时密码或长期 key，再输入目标 VPS、用户和端口，不会沿用上一台 VPS。

菜单 `[13]` 必须输入大写 `UNINSTALL`。卸载后 x-ui/Xray、Nginx、WARP、配置、凭据、证书和灾备继续保留；需要恢复管理工具时运行 `[1]`。

如果 `[1]` 发现远端版本比 EXE 新，会停止且不降级，提示下载与远端相同或更高版本的 EXE。同版本但文件不完整时也不会自动覆盖，需由用户明确执行 `[13] → [1]`。

---

# “无感打开面板”是什么意思

EXE 会：

```text
读取 VPS /etc/proxy-runbook/public.env
→ 自动发现当前随机 panel port + WebBasePath
→ Windows 本地挑选可用端口
→ 建立：
   127.0.0.1:<本地端口>
        ↓ SSH
   VPS 127.0.0.1:<panel port>
→ 自动打开默认浏览器
```

面板仍然没有公网监听。

如果当前 Credential Handoff 里有 panel password：

```text
PANEL_USERNAME → 屏幕显示
PANEL_PASSWORD → 自动单独复制到 Windows 剪贴板
```

可以直接粘贴进密码框。

EXE 退出时，它启动的 SSH tunnel 会自动关闭，不留孤儿 ssh 进程。

---

# 密码/密钥：自动生成，但必须让操作者看到真实值

v0.6 会在生成时全文展示：

```text
Windows SSH Client Private Key
Windows SSH Client Public Key

VPS 新随机登录密码（用户主动轮换/FRESH 默认轮换时）

3x-ui:
  username
  password
  panel port
  WebBasePath
  API Token

REALITY:
  UUID
  PrivateKey
  PublicKey
  shortId
  subId
  vless://
```

重要交接块会自动进入 Windows 剪贴板。

EXE 会提示：

```text
现在粘贴到密码管理器
→ 保存完成后按 Enter
→ 默认清空剪贴板
```

这样高强度随机密码不要求人脑记。

VPS 自身的 SSH Host Private Key 仍**绝不导出**；只展示 public-key fingerprint。

---

# 两个人工必填项

无论中文还是英文，部署/收敛时只有这两项**没有默认值、必须本人输入**：

```text
Cover domain
Let's Encrypt email
```

EXE 会先检查你输入的域名是否已经解析到目标 VPS。

如果没有：

```text
直接告诉你应创建：
A
<你刚输入的域名>
<VPS 公网 IP>
DNS only
```

并原地等待你修改完成再继续。

共享包不会替你猜域名，也不会拿别人部署过的域名复用。

---

# 前台伪装 v0.6

不再生成：

```text
Welcome
This site is online.
```

这种明显占位页。

新的 managed cover 是一个本地静态站：

```text
响应式
Light/Dark
首页
About
Status
404
favicon
robots.txt
零第三方 JS
零外部字体
零 analytics
```

站点品牌文案按域名 hash 从一组中性名字确定，使不同部署不完全同字节，同时不冒充任何真实公司。

已有节点：

```text
旧 runbook 简陋占位页 → 可自动升级
已是 managed cover → 可刷新/优化
用户自定义网站 → 默认保护，不覆盖
```

Nginx 后端同步收敛：

```text
公网 HTTP :80（ACME/普通站点）
REALITY target: 127.0.0.1:8443 TLS
server_tokens off
TLS 1.2/1.3
session cache
安全 headers
静态缓存
8443 严格 localhost-only
```

---

# 自动排障

EXE 先查：

```text
Windows → VPS SSH TCP
```

如果连 SSH TCP 都不到：

```text
不折腾 Xray
→ 引导去厂商 Console/VNC
→ 对照热点/宽带
→ 查 IP/线路/端口
```

能 SSH 后执行结构化诊断，逐项显示：

```text
✓ GOOD
WARN
ERROR
为什么
下一步
哪些可以自动修
哪些必须人工处理
```

当前覆盖：

```text
Public IP / runtime metadata
x-ui
nginx
fail2ban
UFW
443 listener
8443 localhost-only
panel localhost-only
DNS
certificate
cover 前台
WARP MASQUE localhost proxy
磁盘
DOCKER-USER DROP 提示
```

安全自动修复会先备份，只自动处理确定性项目。

绝不会：

```text
看到 DROP 就删
看 443 不对就直接覆盖
自动 full-upgrade
自动重启 VPS
自动升级 3x-ui/Xray
```

---

# 生产 REALITY 仍保留人工闸

自动化再懒，也不能把这个保险删掉：

```text
24443 shadow
→ EXE 图形工作区给出测试 vless://
→ 你亲自用客户端真上网
→ 明确 Y
→ 才写正式 443
```

这是防止“一键脚本把最后一个能用的节点一键干死”。

---

# 源码/手册

完整 Bash/PowerShell source 仍然保留，方便审计：

```text
proxy-runbook-toolkit-v0.9.5.tar.gz
```

完整技术说明：

```text
代理节点从零部署运维与灾难救援技术手册-v0.6.md
```

