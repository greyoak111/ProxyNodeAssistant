# CHANGELOG v0.6

## Single EXE

新增 Windows x64：

```text
TextNodeAssistant-v0.6-win64.exe
```

Go 标准库构建；内嵌 v0.6 toolkit tar.gz。

### EXE 支持

- 中/英双语菜单与引导。
- 每次运行输入 host/user/SSH port，不保存节点资料。
- Windows OpenSSH 缺失时可请求 UAC 自动安装。
- 自动生成 per-node Ed25519 SSH client keypair。
- 真 Private/Public Key 显示 + clipboard handoff。
- 自动安装 public key并真实 BatchMode 验证。
- 内嵌 toolkit 自动 SCP/解包/bootstrap。
- domain + Let's Encrypt email 必须本人输入。
- DNS A 记录本地引导/轮询。
- 自适应 FRESH / EXISTING。
- 凭据交接自动复制，保存后可清空 clipboard。
- 自动发现 panel port/path。
- 隐藏 ssh child process 建 127.0.0.1 panel tunnel，自动开浏览器。
- EXE 退出自动 kill 自己创建的 tunnel。
- VPS/password / panel credentials / SSH key rotation。
- 结构化 diagnosis + safe repair。
- 紧急报告下载。
- cover frontend/backend 优化。

## Cover

新增 managed polished cover：

- 首页 / About / Status / 404
- 响应式 Light/Dark
- no external JS/font/analytics
- deterministic neutral site name per domain
- favicon / robots
- Nginx TLS/backend hardening
- custom existing sites are preserved by default

## Diagnosis

新增：

```text
linux/16-auto-diagnose.sh
linux/17-safe-auto-repair.sh
```

诊断结果内置中英双语解释和 next action。
