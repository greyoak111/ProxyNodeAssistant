# Privacy Model / 可分享包隐私规则

v0.6 开始，共享包遵守：

1. **零真实节点默认值**：不内置真实 VPS IP、域名、SSH 用户、提供商、节点名。
2. **一用一输**：启动时输入 VPS IP/主机名、SSH 用户、SSH 端口；远端必须由用户亲自输入 cover 域名和 Let's Encrypt 邮箱。
3. **初始 VPS 密码不读取、不保存**：只交给系统 `ssh/scp` 自己弹出的密码提示。
4. **自动生成的新密码/密钥必须真实展示**：不是 `***`、不是假示例。
5. **共享包与运行态分离**：
   - 共享包：永远不含用户凭据。
   - Windows 本地运行态：SSH key 存 `%USERPROFILE%\.ssh\proxy-runbook\...`。
   - VPS 运行态：凭据交接档只存在 `/root/.config/proxy-runbook/`，权限 600。
6. **VPS SSH host private keys 永不导出**。只展示 host public-key fingerprint；服务器 host private key 留在 `/etc/ssh/`。
7. 3x-ui / REALITY / VPS 登录凭据自动生成后必须给用户一个明确的 HANDOFF 区块，方便立刻存进密码管理器。
8. 不把任何一次真实部署的 `node.env` 打回共享 ZIP/TAR。
