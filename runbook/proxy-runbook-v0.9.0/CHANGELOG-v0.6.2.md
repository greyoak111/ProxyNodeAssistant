# CHANGELOG v0.6.2

这是针对 v0.6.1 菜单 `[3]` 出现 `structured diagnosis failed (exit 1):` 空错误的热修版。

- 诊断输出改为带首尾标记的 V1 记录协议，不再依赖远端 `jq`。
- 捕获型远端命令失败时同时保留 stderr 与 stdout；两者均为空时给出明确提示。
- `Connection to … closed.` 仍会从错误摘要中剔除，不能污染业务数据。
- 每次执行依赖 runbook 的菜单功能前检查 `TOOLKIT_VERSION`。
- 远端工具包缺失或较旧时，EXE 自动上传并切换到 v0.6.2，然后继续原操作。
- 诊断发现 ERROR/WARN 是有效诊断结果，不再作为 SSH/执行器故障处理。
- 增加无网络、无 jq 条件下的诊断协议回归测试。

v0.6.1 的 SSH 输出隔离、handoff 验证、panel 元数据回退和失败硬停止修复全部保留。
