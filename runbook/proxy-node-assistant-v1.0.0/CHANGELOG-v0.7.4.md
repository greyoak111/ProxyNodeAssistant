# v0.7.4

- 新增远端菜单 `[15]`：标准双登录选择，先生成并完整验证当前配置压缩包，再清理严格限定名称的旧管理备份，最终只保留一份。
- 当前配置包只收录实时配置/身份和小型运行配置快照，不复制 x-ui 程序树、日志、服务状态或旧 `before` 模板。
- 新包通过 gzip、重新解包、SHA-256 清单、必需数据库、格式标记和历史文件排除验证之前，不执行任何旧备份删除。
- 完整灾备 `[9]` 压缩完成或失败后都会清理展开目录，避免目录与 `.tar.gz` 双份占用。
- 升级/卸载管理清单加入直接前代 v0.7.3。

- EXE 启动时先验证完整 Windows OpenSSH 套件；缺失时只安装一次并复验，失败明确退出，不循环弹安装。
- 新增纯本地菜单 `[14]`：配置、撤销或查看 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY`，固定对准 `127.0.0.1:10808`；不会请求 VPS 登录。
- 本地代理配置和撤销都会执行用户级持久写入、当前进程同步、Windows 环境变更通知、回读验证和 10808 监听状态检查。
- 升级/卸载管理清单加入直接前代 v0.7.2，避免更新到 v0.7.4 后遗漏旧目录和上传包。

- 修复 3x-ui 3.6.0 独立面板节点使用 `shareAddrStrategy=node`、但没有 Node 记录时把订阅节点地址生成为 `localhost:443`，导致客户端延迟恒为 `-1`。
- Reality 新建、影子测试、提交和既有节点收敛均强制 `shareAddrStrategy=custom`，共享地址取实时 VPS 公网 IPv4；诊断和安全修复也能识别/纠正漂移。
- 3x-ui 订阅服务固定只监听 `127.0.0.1:2096`，由现有 Cover HTTPS 的 `/sub/` 路径反向代理；面板复制出的订阅 URI 固定为 `https://<cover-domain>/sub/<sub-id>`。
- 最终交接单新增每个客户端的 HTTPS 订阅 URL；自动诊断会真实下载并解码订阅，确认生成的节点地址不是 localhost。
- 修正派生源码遗漏：`TOOLKIT_VERSION` 现在与 EXE 的 `0.7.4` 强制一致；新增测试阻止目录名、EXE 常量与版本文件再次漂移。
- ACME location 显式 `auth_basic off`、`allow all`，避免上层访问控制令公网 challenge 返回 403。
- `05-cover-bootstrap.sh` 显式使用 `umask 022` 和 755 Webroot 目录，修复从总向导继承 `umask 077` 后 Nginx 因 `Permission denied` 返回 403。
- Certbot 前加入随机 challenge 的本机与公网双重下载校验；公网失败停在 `PUBLIC_ACME_HTTP_PREFLIGHT`，不再直接请求 CA。
- 结构化诊断新增 `COVER_HTTP_FORBIDDEN`，区分 DNS 正确但公网 Nginx 返回 403 的故障。
- WARP 安装会在访问 Cloudflare APT 源前原子刷新官方 keyring；已有旧源导致首次 `apt-get update` 报 `NO_PUBKEY` 时，不再卡死在刷新密钥之前。
- 兼容新版 3x-ui/Xray UUID 接口返回 `{\"uuid\":\"...\"}` 对象；统一提取并严格校验 UUID，禁止把整段 JSON 写进 inbound 或 `vless://` 链接。
- 所有远端菜单项统一使用必须明确选择的二级登录菜单：临时密码 / 节点专属长期 SSH key / 取消。
- 每项远端操作都重新询问目标 VPS，不再静默复用上一次缓存连接，可在同一 EXE 会话中连续处理不同 VPS。
- 临时密码模式由 Windows OpenSSH 直接读取一次密码；EXE 不读取、不保存密码。
- 为多步 SSH/SCP 生成的一次性 key 不显示、不进剪贴板、不写入长期 key 目录；本项结束前从 `authorized_keys` 精确撤销并删除本机临时目录。
- 新机密码验证成功后才询问是否绑定；明确同意后才把已验证 key 提升到长期目录并显示/复制真实私钥。
- 新增 `[K]`：清空当前目标以切换 VPS，或从远端精确撤销长期公钥并把本机 key/known_hosts 移入可恢复备份。
- 清理命令逐行精确匹配完整公钥，不触碰其他长期 key；正常返回、失败、退出和 `Ctrl+C` 均尝试清理。
- 升级/卸载管理清单明确保留 v0.6.7、v0.6.8、v0.6.9、v0.7.0、v0.7.2、v0.7.3、v0.7.4，避免漏掉直接前代。
- 修复部分 Windows 环境中单次 `ssh-keyscan` 被过早判定为无 Host Key 的问题。
- 固定使用同一目录中的完整 Windows OpenSSH 套件，避免 PATH 中混合 `ssh` 与不同来源的 `ssh-keyscan`。
- Host Key 扫描最多进行三次有界尝试；有效、匹配目标的 Host Key 不再因扫描进程非零退出码被丢弃。
- 严格过滤错误主机、错误端口、不支持算法、无效 Base64、过短记录和 SSH 噪声。
- 扫描彻底失败时输出 OpenSSH 绝对路径及逐次退出码/有效密钥数，方便定位本机拦截；仍然失败关闭。
- 修复 Windows 首次连接时 OpenSSH `Are you sure ... (yes/no/[fingerprint])?` 无法从 EXE 窗口读取键盘、随后 `Host key verification failed` 的问题。
- 首次连接先由 `ssh-keyscan` 读取主机公钥，由 EXE 显示指纹并使用自己的 `[y/N]` 输入确认；默认不信任。
- 确认后的公钥保存在该节点本地密钥目录中的专用 `known_hosts`，全部 SSH/SCP 强制使用 `StrictHostKeyChecking=yes`。
- 不采用 `StrictHostKeyChecking=no` 或静默 `accept-new`；主机密钥变化时继续失败关闭，防止中间人攻击。
- 只有 Host 指纹确认完成后才生成本项临时 key；只有密码验证成功且明确绑定后才显示长期 SSH 私钥。
- 需要 VPS 初始密码时，OpenSSH 的 stdin/stdout/stderr 直接连接真实 Windows 控制台；密码输入无回显，EXE 不读取或保存。
- 保留 v0.6.6 的 3x-ui API Token 复用、WARP 路由幂等、失败硬停止、版本状态机和安全卸载。

