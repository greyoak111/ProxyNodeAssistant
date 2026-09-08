# CHANGELOG v0.6.3

本版由真实 VPS 现场复现与验证驱动。

- 修复 `sshd -T | awk '…; exit'` 在 `set -o pipefail` 下返回 SIGPIPE/141，导致向导停在 `INITIALIZATION`。
- 清理 runbook 中的 `head -1` 早退管道，改为会完整消费输入的首行提取方式。
- 菜单 `[1]` 同时检查 `TOOLKIT_VERSION` 和 `TOOLKIT_BUILD_ID`：完全相同才跳过上传与 bootstrap，仅缺失/过旧时按需更新一次。
- 菜单 `[2]`—`[10]` 不再自动上传/初始化工具包；版本不符时明确提示只运行一次 `[1]`。
- 基础命令齐全时跳过 `apt-get update/install`，不再把幂等检测表现成重复安装。
- 诊断在 `public.env` 缺失时调用 panel 元数据多级探针，不再误报 `PANEL_METADATA` 缺失。
- 公网 IP 运行态尚未写入时显示信息项，而不是误报 IP 不一致。
- Cover 后端兼容 Ubuntu 22.04 的 Nginx 1.18，使用 `listen 127.0.0.1:8443 ssl http2`，不再写入不受支持的 `http2 on`。

v0.6.1/v0.6.2 的 SSH 输出隔离、handoff 验证、无 jq 诊断协议和 panel 多级读取全部保留。
