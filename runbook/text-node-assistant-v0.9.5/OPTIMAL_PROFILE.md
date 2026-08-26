# v0.6 自适应“最优”配置定义

这里的“最优”不是乱改 sysctl、追 benchmark，而是**对当前单人自用 VLESS+REALITY 节点，尽量减少暴露面、状态分叉和维护负担**。

## 自动收敛目标

- 公网只需要：当前 SSH 端口、TCP 80、TCP 443。
- `3x-ui` 面板：保留该节点自己的随机/现有高位端口，但监听地址必须是 `127.0.0.1`，只通过 SSH tunnel。
- Nginx REALITY target：`127.0.0.1:8443`，不得公网绑定。
- Cloudflare WARP Local Proxy：`127.0.0.1:40000`，MASQUE。
- OpenAI/ChatGPT 域名：通过 Xray 持久 `warp-masque` outbound；其他流量继续 VPS direct。
- `fail2ban` 启用。
- `UFW` 启用，但**不删除未知/自定义规则**；只补必要规则，并清理本手册明确禁止的“Anywhere -> 8443 / 实际 panel port / 40000”公开规则。
- 内核支持 BBR 时：`fq + bbr`；不支持就不硬开。
- Nginx 配置必须 `nginx -t` 通过。
- Certbot 有证书时检查续期；没有证书时只在 DNS 已指向本机后申请。
- 3x-ui 使用官方 stable 安装；**已有节点不自动升级 3x-ui/Xray**。
- 已有生产 443 不直接重写：如果 REALITY target 不符合本地 self-steal 目标，只创建 24443 影子节点，真测通过后才允许迁移。
- 每次有状态修改前先做 root-only 备份。
- Windows 为每个 `host + SSH user` 自动生成独立 Ed25519 client key；公钥安装到 VPS，私钥保留在本机，并在首次生成/交接时全文显示。
- VPS 登录密码可由脚本随机轮换并全文显示；已有节点不会每次运行都偷偷轮换。
- 新装 3x-ui 的随机用户名、密码、WebBasePath、API Token 必须全文交接；已有面板密码不可恢复时，只能显式选择“生成新的并显示”，不能伪造。
- REALITY UUID / PrivateKey / PublicKey / shortId / client link 自动生成后全文交接。

## 明确不做

- 不自动 `apt full-upgrade`。
- 不自动重启 VPS。
- 不自动关闭 SSH 密码登录。
- 不自动改已有 UUID/PrivateKey/shortId。
- 不为了“更快”改一堆不可证明的 TCP magic numbers。
- 不直接把面板/8443/WARP proxy 暴露公网。
- 不复活旧 WireGuard/WARP 路由表方案。
- 不复活“Xray 运行时注入 + 2 分钟 watchdog”。

所以 v0.6 的“已有节点优化”原则是：

```text
能证明有漂移 → 备份 → 影子/可回滚修复
已经健康 → 不碰
不确定 → 报告，不自作主张
```
