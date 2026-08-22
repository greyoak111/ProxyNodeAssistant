# ProxyNodeAssistant v0.9.0 Android 完整使用说明

## 1. 这是什么

Android 版是原生 Kotlin + Jetpack Compose 应用，不是网页壳、Termux 脚本或远程桌面。它在手机内完成 SSH 认证、Host Key 校验、SCP 传输、交互提示、日志、凭据交接和 127.0.0.1 面板隧道，远端施工继续复用与 Windows 正式版完全相同的 `proxy-runbook v0.9.0`。

最低 Android 7.0（API 24），面向 Android 16（target API 36）。APK 是 universal 包，可安装在常见 ARM64、ARMv7 和 x86_64 Android 设备上；SSH 部分为纯 Java/Kotlin，不要求 root。

## 2. 安装

1. 把 `ProxyNodeAssistant-v0.9.0-android-universal.apk` 传到手机。
2. 在系统设置中仅为当前文件管理器或浏览器临时允许“安装未知应用”。
3. 安装 APK，启动 `PNA // NODE OPS`。
4. Android 13 及以上会询问通知权限。允许后，面板 SSH 隧道可通过前台服务稳定保持，并在通知中提供停止按钮；拒绝通知不会给应用读取联系人、短信或相册的权限。

APK 不要求存储权限。报告、救援包和加密密钥备份通过 Android 系统文件选择器导出，应用只能访问本人明确选择的目标。

## 3. 第一次连接

每个远端操作都重新进入目标与认证页：

- `节点长期 KEY`：按 `SSH用户@主机:端口` 独立查找。没有绑定 key 时会临时询问一次密码，密码验证成功后再明确询问是否绑定。
- `临时密码`：密码只用于当前 SSH 认证，不写日志、不进剪贴板、不写磁盘。

首次遇到一台 VPS，应用会显示服务器公开 Host Key 的 SHA-256 指纹。与厂商控制台核对后输入大写 `TRUST`。以后 Host Key 发生变化时不会自动接受，必须在确认服务器确实重装或换钥后输入不同的 `REPLACE`。只有密码/密钥认证和加密握手都成功后，新的 Host Key 才会保存。

最近目标只记录主机名/IP、SSH 用户、端口、标签和最后使用时间，不记录密码。可在 `NODES` 中单独删除或全部清空。

## 4. 功能矩阵

| 编号 | Android 图形功能 | 行为 |
|---|---|---|
| 1 | 安装/升级/自适应优化 | 唯一安装入口；缺失则安装、旧版则升级、同一完整构建跳过上传，新于客户端则拒绝降级；随后手填域名和邮箱、选 1—15/R/A 模板、校验 DNS、执行施工、验证交接单，可选整理备份和打开面板。 |
| 2 | 打开 3x-ui | 读取结构化面板端口/路径，建立 Android 本机 `127.0.0.1` 随机端口隧道，浏览器不暴露公网面板。 |
| 3 | 自动体检 | 检查 SSH、x-ui、Nginx、WARP、订阅、端口和关键配置。 |
| 4 | 安全修复 | 先备份，只处理脚本能够确定的问题。 |
| 5 | VPS 密码轮换 | 生成高强度随机密码，验证交接单后才允许显示/复制。 |
| 6 | 3x-ui 身份轮换 | 更新面板用户名/密码并验证交接单；会注销旧会话，可能影响原有 2FA。 |
| 7 | 凭据交接单 | 只接受含运行标记且至少有一个有效字段的结构化交接单；空输出和 `Connection closed` 会失败关闭。 |
| 8 | 伪装站/Nginx | 列出 15 套内置模板，支持随机、按域名稳定或指定编号。 |
| 9 | 完整灾备 | 生成包含程序/身份的较大备份。 |
| 10 | 紧急报告 | 生成、下载到应用私有目录，并通过系统分享/保存。 |
| 11 | SSH key 绑定/轮换 | 先安装并实测新钥，成功后才撤旧公钥；失败自动恢复旧绑定。 |
| 12 | 清空剪贴板 | 清空本应用写入的秘密剪贴板内容。 |
| 13 | 卸载远端工具包 | 只移除内嵌工具包和维护入口，保留节点、配置、凭据与备份。 |
| 14 | Android 本地控制 | 实测 `127.0.0.1:10808`；可让本应用的服务商 API 查询走该 HTTP 代理或恢复直连；SSH 不走 HTTP 代理。 |
| 15 | 整理远端备份 | 输入 `CLEAN` 后新建并验证一份当前配置备份，只清理脚本已知旧备份。 |
| 16 | 自适应性能档 | 侦测/自动/低配/标准/高配/回滚，所有变更可回滚。 |
| 17 | SSH/vnStat 流量 | 安装或读取低开销网卡计数；明确标记为估算，不等同厂商计费。 |
| 18 | 全量拆除 | 先下载救援包，再按计划移除本工具可识别的施工；旧版本基线不完整时有第二层确认。 |
| T | 服务商流量中心 | KiwiVM `VEID + API Key` 真实查询、阈值预警；其他无统一 API 的厂商回退到 SSH/vnStat。 |
| K | 密钥仓 | 查看绑定/多代备份、全部转备份态、恢复指定一代、删除指定备份、加密导出/导入。 |
| H | 节点历史 | 查看和删除非秘密目标历史。 |

## 5. 面板隧道

操作 2 或操作 1 末尾选择打开面板后，应用会：

1. 验证远端脚本成功退出；
2. 读取带开始/结束标记的面板元数据；
3. 拒绝空端口、越界端口、空路径、含查询/换行/反斜杠的危险路径；
4. 在 Android 本机选择空闲端口并创建 SSH 转发；
5. 由前台服务持有 SSH 会话，再打开浏览器。

状态条和系统通知均可关闭隧道。关闭会同时销毁本地监听与 SSH 连接，浏览器之后无法继续加载属于正常结果。

## 6. SSH key 与备份

节点私钥经 Android Keystore 管理的 AES-GCM 主密钥加密后保存；主密钥不可导出。`转入备份态` 只空出该目标的绑定槽，不会静默删除 VPS 上的公钥。多次轮换会保留多代备份，并按创建时间单独显示。

若要防止卸载应用或手机损坏造成丢失：

1. 进入 `KEYS`，点 `EXPORT`。
2. 输入并确认至少 12 位的独立备份口令。
3. 用系统文件选择器保存 `.pnakeys`。
4. 把文件和口令分开保管。

导出文件使用 PBKDF2（250,000 次）派生 AES-256-GCM 密钥。导入时选择文件并输入原口令；错误口令或文件被修改都会失败。若导入记录与现有绑定槽冲突，它会进入备份态，不覆盖当前可用 key。

应用无法找回忘记的导出口令。Android Keystore 数据也不会随普通系统云备份导出。

## 7. KiwiVM 流量

KiwiVM 页面只需要每台实例自己的 `VEID` 和 Private API Key，不要输入网站账户密码。API Key 默认仅用于本次查询；勾选“成功后加密保存”时，只有 API 返回成功后才进入 Android Keystore 加密仓。再次查询同一 VEID 时可留空密钥框使用存档，也可点 `FORGET KEY` 删除。

请求使用 HTTPS POST 发往 `https://api.64clouds.com/v1/getServiceInfo`，API Key 不进入 URL、普通日志或错误摘要。流量结果应用厂商返回的 `monthly_data_multiplier`，显示已用/额度、百分比、重置时间、暂停与策略状态。阈值只在本人查询时判断，不做高频后台轮询。

若在本地页启用 10808，本应用的服务商 API 请求走 `127.0.0.1:10808`；先点 `CHECK PORT` 确认真有 HTTP 代理监听。该开关不修改 Android 全局代理，也不会影响 SSH。

## 8. 失败关闭规则

- 任一远端命令非零退出：不复制凭据、不打开面板、不继续后续步骤。
- 交接单没有开始/结束标记、运行标记或有效字段：拒绝。
- 面板元数据为空或不安全：拒绝建立隧道。
- 远端同版本构建较新：拒绝降级，提示换新客户端。
- 新 SSH key 未通过独立登录验证：撤销新公钥并恢复旧绑定。
- 点击停止：关闭当前 SSH/提示等待，不把 EOF 当成空输入反复提交。

## 9. 权限与本地数据

- `INTERNET`：SSH、SCP、DNS 与用户主动发起的 KiwiVM HTTPS 查询。
- `POST_NOTIFICATIONS` / 前台服务：保持面板隧道，并提供显式停止入口。
- 不申请联系人、短信、电话、定位、相机、麦克风或全盘存储权限。
- `allowBackup=false`，系统备份不会上传 Host Key、SSH 私钥或服务商 API Key。
- 报告和救援包先存应用私有目录，只有本人点击 `EXPORT / SHARE` 后才交给选定应用。

## 10. 源码构建

在仓库根目录的 PowerShell 中运行：

```powershell
.\android\build-android.ps1 -Provision -Task Debug
.\android\build-android.ps1 -Task Test
.\android\build-signed-release.ps1
```

首次 `-Provision` 会在仓库忽略目录 `.android-tools` 中安装固定构建链：Microsoft JDK 17、Gradle 9.5、Android command-line tools、API 37.0 平台和 Build Tools 36.0.0。不会修改系统级 Java/Android Studio 配置。

签名脚本首次运行会创建持久发布 key：

```text
%LOCALAPPDATA%\ProxyNodeAssistant\android-signing\pna-release-v1.jks
%LOCALAPPDATA%\ProxyNodeAssistant\android-signing\pna-release-v1.password.dpapi
```

口令用当前 Windows 用户的 DPAPI 保护。以后 APK 更新必须使用同一 keystore；请把这两个文件一并安全备份。输出位于：

```text
android\dist\ProxyNodeAssistant-v0.9.0-android-universal.apk
```

## 11. 隐私发布检查

发布 APK 和源码不得包含真实 VPS IP、域名、邮箱、密码、API Key、Token 或私钥。APK 内资产名固定为 `proxy-runbook-toolkit-v0.9.0.tgz`（上传到远端时恢复标准 `.tar.gz` 名），构建前应校验其 SHA-256 与正式 Windows 包一致，并对源码、解包 APK 和内嵌 tar 做二次扫描。
