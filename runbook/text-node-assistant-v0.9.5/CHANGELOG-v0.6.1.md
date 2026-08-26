# CHANGELOG v0.6.1

这是针对 v0.6 用户日志的失效关闭（fail-closed）修正版。

## Windows EXE

- SSH 捕获明确分离 stdout、stderr 与退出码。
- `Connection to … closed.` 只能作为 SSH stderr，不能成为交接单或 panel 元数据。
- 交接单必须含成对标记、`HANDOFF_RUN_STARTED` 与至少一个已知凭据/运行态字段；空内容一律不复制。
- 远端施工非零时立即停止，不复制交接单，不询问打开 panel。
- 失败时读取 `/etc/text-node-assistant/last-run.env` 和 Cover 阶段状态，直接报告失败阶段。
- panel 元数据通过专用无 TTY 命令读取，并验证端口范围与 WebBasePath。
- SSH 隧道启用 `ExitOnForwardFailure=yes`，只有本地监听真正建立后才打开浏览器。

## 远端 runbook

- panel 端口/路径发现后立即原子写入 `/etc/text-node-assistant/public.env`，不再等证书、Cover、WARP 全部完成。
- 新增 `linux/18-panel-metadata.sh`，按 `public.env → x-ui setting -show → install-result.env` 回退读取。
- 自适应施工持续写入 `/etc/text-node-assistant/last-run.env`；Cover 施工另写 `/etc/text-node-assistant/cover-last-run.env`。
- 远端失败打印 `TNA_REMOTE_FAILURE` / `TNA_COVER_FAILURE` 阶段标记。
- panel 设置解析兼容 `port/panelPort` 与 `webBasePath/web base path`。
- Certbot 续期 dry-run 失败降级为警告；已成功签发的证书不因此被误报为整个首次施工失败。

## 安全与隐私

- 包内不含真实 VPS IP、域名、账户、密码、SSH 私钥或节点配置。
- 域名和 Let's Encrypt 邮箱仍必须由操作者当次输入。
- 24443 真机验货仍保留人工确认闸门。
