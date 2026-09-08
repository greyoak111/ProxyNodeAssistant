# v0.9.0

- revision 5 新增 `[18]` 全量拆除：先下载并校验完整救援包，再恢复精确基线或执行经双重确认的 legacy 有界全拆；始终保留 SSH/key/22 与共享基础包。
- 首次施工会在任何 package/service/firewall/x-ui/Nginx/WARP/performance 改动前捕获一次原始基线；检测到旧施工标记时只记录 `LEGACY_UNCERTAIN`，不伪造原始状态。
- 修复 Nginx `reload` 刚返回时旧 worker 仍短暂接收连接，导致随机 ACME 探针偶发 404、施工误停的问题。探针现在会在 reload 前落盘，reload 后分别轮询本机与公网，并在所有成功/失败分支自动清理。
- 修复图形客户端停在 24443 真机验货：远端无换行 `read -p` 现在改走 Base64 行提示帧，GUI 可立即解锁“是/否”；日志统一剥离 ANSI 颜色码。
- 中断后重跑会验证并复用工具生成的既有 24443 shadow，重新显示测试链接，不会再次创建同端口入站。
- hotfix4 兼容旧状态文件使用的 `TEST_PORT` 字段；复用前仍会向 3x-ui 核验该端口确实是 VLESS+REALITY，修复“24443 已存在却再次创建并报错”。
- 新增单调递增 `TOOLKIT_BUILD_REVISION`；菜单 `[1]` 可更新同版本旧构建，同时阻止旧 EXE 覆盖同版本新构建。

- Synchronize the Windows application and remote toolkit version at `0.9.0`.
- Add `linux/20-adaptive-performance.sh` with detect/auto/low/standard/high/rollback modes, exact managed-file backups, runtime sysctl restoration, bounded low-memory zram, and failure rollback.
- Add `linux/21-traffic-status.sh` for explicit vnStat status, confirmed installation/initialization, and machine-readable daily JSON.
- Expose performance and traffic operations in the remote maintenance menu and full status report.
- Extend structured diagnosis with informational performance-profile and vnStat readiness checks.
- Retain the 15 local-only cover templates, version idempotency, strict SSH host-key handling, panel metadata validation, backups, and fail-closed deployment behavior.
