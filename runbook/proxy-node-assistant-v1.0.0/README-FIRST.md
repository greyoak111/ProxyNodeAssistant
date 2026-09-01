# ProxyNodeAssistant v1.0.0 重置线

> 本版本以稳定的 v0.9.0 为底座重新迭代，彻底移除后续实验版的本机 admin/恢复、UI 门禁、设备身份/准入、controller/设备邀请/租约、私人网盘及其远端服务。保留成熟的普通 SSH 密码/key 登录、3x-ui、REALITY、Nginx、WARP、备份、诊断、拆除恢复和完整凭据交接能力。灰云直连、橙云 CDN/XHTTP、双路共存和全部施工偏好收拢到菜单 `[1]` 的显式方案中。

菜单 `[1]` 不再靠隐式默认值猜测用户意图。新施工会强制选择仅灰云、仅橙云或双路；已有受管节点还可选择 `[0]` 保持现有拓扑。随后逐项确认灰云/橙云域名与邮箱、伪装模板、性能档、WARP 策略、备份清理及是否打开面板，展示完整预览，只有输入大写 `APPLY` 才会上传工具包并修改 VPS。域名、邮箱和密码不写回共享 EXE 或工具包。

橙云模式采用受控事务：先暂存 XHTTP 与 Cloudflare 入口，要求操作者用实际客户端导入严格的 `hostname:8443` 链接并完成真实浏览，确认后才提交；失败或取消会回滚到施工前拓扑。灰云切换只撤销本工具拥有的 CDN/8443 组件，不破坏 REALITY。

Windows EXE 在主菜单前一次性检查/安装并验证 OpenSSH；菜单 `[14]` 可在不登录 VPS 的情况下配置、撤销或查看当前用户的本地 `127.0.0.1:10808` 代理环境变量。

菜单 `[16]` 检测并应用 auto/low/standard/high 性能档，所有受管改动都先备份并支持回滚。菜单 `[17]` 使用 vnStat 提供 VPS 侧流量估算；菜单 `[18]` 先把救援包下载并校验到 Windows，再恢复施工前基线或执行旧节点有界全拆。服务商精确计费口径由 Windows EXE 的本地 `[T]` 流量中心查询。

菜单 `[15]` 通过标准临时密码/长期 key 二级登录，在新当前配置包完整验证后清理严格限定名称的旧管理备份，并确保最终只保留一份 root-only 当前配置压缩包。

## 最推荐的交付物

Windows x64 用户优先只用：

```text
ProxyNodeAssistant-v1.0.0-win64.exe
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

每项远端操作都重新确认目标与登录方式；可选历史只保存节点 IP/主机名、SSH 用户和端口，可随时单条删除或清空，不保存密码、域名、邮箱或私钥。

---

# EXE 菜单

支持中文 / English 一键切换：

```text
1  【唯一安装入口】安装 / 升级 / 拓扑切换 / 自适应优化（显式预览 + APPLY）
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
T  服务商流量中心（纯本地；秘密可选存入 Credential Manager）
K  管理已绑定 key：换 VPS / 远端撤销 + 本机可恢复备份
H  管理 VPS 登录历史
L  中英切换
C  清空当前选择和隧道（不删除绑定）
```

除 `[12]`、`[14]`、`[T]`、`[H]`、语言和退出等纯本机项目外，每个远端项目都会先重新选择临时密码或长期 key，再输入目标 VPS、用户和端口，不会沿用上一台 VPS。

菜单 `[13]` 必须输入大写 `UNINSTALL`。卸载后 x-ui/Xray、Nginx、WARP、配置、凭据、证书和灾备继续保留；需要恢复管理工具时运行 `[1]`。

如果 `[1]` 发现远端版本比 EXE 新，会停止且不降级，提示下载与远端相同或更高版本的 EXE。同版本但文件不完整时，`[1]` 会在用户确认 `APPLY` 后原位修复管理工具；其他菜单仍只读报错，不会偷偷上传。若探测到更高修订或不同构建 ID，则必须换用匹配的 EXE。

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

v1.0.0 会在生成时全文展示：

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

SS2022 TCP 与 CDN/XHTTP（按实际启用线路）也会在完整交接单中输出对应订阅链接和参数。
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

# 路线相关输入必须由本人填写

菜单 `[1]` 会先让操作者选择路线，再只询问该路线真正需要的字段；这些值**没有隐藏默认值，也不会跨节点复用**：

```text
仅灰云：Gray/DNS-only domain + 对应 ACME email
仅橙云：Orange/Proxied domain + 对应 ACME email
双路：分别填写 Gray domain/email 与 Orange domain/email
已有受管节点选择 [0]：保持当前路线和已验证参数
```

EXE 会按路线分别检查 DNS 与 Cloudflare 入口条件。灰云域名必须直接解析到目标 VPS；橙云域名必须开启代理并按屏幕引导完成 SSL/TLS、缓存绕过及真实客户端验货。

如果没有：

```text
直接告诉你应创建：
A
<你刚输入的灰云域名>
<VPS 公网 IP>
DNS only
```

并原地等待你修改完成再继续。

共享包不会替你猜域名，也不会拿别人部署过的域名或邮箱复用。预览阶段可以返回修改；输入 `APPLY` 后才进入会改动远端的施工阶段。

---

# 前台伪装与模板库

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
proxy-node-assistant-toolkit-v1.0.0.tar.gz
```

完整技术说明：

```text
代理节点从零部署运维与灾难救援技术手册-v0.6.md
```

