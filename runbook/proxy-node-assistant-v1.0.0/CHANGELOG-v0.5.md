# CHANGELOG v0.6 — Privacy-first / One-run-one-input

## 删除

- 删除所有真实节点 IP。
- 删除所有真实 cover domain。
- 删除 provider / ASN / 当前节点名。
- 删除 `CURRENT_NODE.env/.md`。
- 删除固定“当前节点”维护器。
- 删除历史版本中会暴露某次真实部署拓扑的 changelog。

## 输入模型

共享包不再提供真实默认值。

每次 Windows 启动必须输入：

```text
VPS IP / hostname
SSH user
SSH port
```

每次远端自适应施工必须由操作者本人输入：

```text
cover domain
Let's Encrypt email
```

二者没有默认值。

## SSH / VPS credentials

- Windows 自动生成每 `host + user` 独立 Ed25519 keypair。
- 真实 SSH Private/Public Key 在终端全文显示。
- 只把 Public Key 写入 VPS。
- Public-key 登录必须真实验证后才上传工具包。
- 初始 VPS 密码只由 OpenSSH 自己读取；runbook 不读取/保存。
- Fresh 节点可选择将 provider-supplied login password 随机轮换或改为自定义值，真实新密码全文显示。
- Existing 节点不会每次运行自动轮换密码；用户显式选择后才做。
- VPS SSH host Private Key 永不导出，只显示 public-key fingerprint。

## 3x-ui credentials

Fresh unattended install：

```text
不预设 username
不预设 password
不预设 panel port
不预设 WebBasePath
不预设 API Token
```

完全使用当前 3x-ui 每实例安全随机生成。

生成的真实凭据全文交接，并保留 root-only：

```text
/etc/x-ui/install-result.env
/root/.config/proxy-runbook/HANDOFF-SECRETS.txt
```

Existing panel 密码不可恢复时不伪造；可以显式选择“随机轮换”“自定义账号/密码”或取消，并在成功后显示真实值。

## REALITY

- UUID / X25519 / shortId / subId 自动生成。
- Private/Public Key、UUID、shortId、subId、vless:// 在 HANDOFF 全文显示。
- shared package 永远不保存这些值。
- Production 443 仍必须 shadow -> 真人验证 -> commit。

## Panel

不再强制固定 panel port。

```text
fresh: 使用 3x-ui 自己生成的随机 panel port
existing: 保留现有 panel port
all: listenIP -> 127.0.0.1
```

Windows panel tunnel 从 VPS 的运行态非秘密 metadata 自动发现端口/path。

## Runtime vs distributable

共享包：

```text
零节点身份
零秘密
```

VPS runtime：

```text
/etc/proxy-runbook/public.env
/root/.config/proxy-runbook/HANDOFF-SECRETS.txt
```

Windows runtime：

```text
%USERPROFILE%\.ssh\proxy-runbook\...
```

运行态永不回写共享 ZIP/TAR。
