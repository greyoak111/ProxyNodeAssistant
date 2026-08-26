# 构建与验证

需要 Go 1.23 或更新版本、Windows 自带 `tar.exe`，以及 .NET Framework 4.x 的 64 位 C# 编译器和 WPF 程序集。Windows 10/11 的系统 .NET Framework 通常已经提供后两项。

只构建默认 x64，在本目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

一次构建全部 Windows PC 架构，双击：

```text
build-all-pc.bat
```

它依次生成 x64、x86 和 ARM64 三个单文件 GUI。x64/x86 在兼容构建机上执行运行时冒烟测试；ARM64 在非 ARM64 构建机上交叉编译并做静态校验，不会伪报为已原生运行。

构建脚本会依次：

1. 重建 runbook 内部 `SHA256SUMS.txt` 和内嵌 tar.gz。
2. 执行全部 Shell 语法/协议门禁，包括部署状态机、第三方供应链和私人网盘回环/密码 stdin 静态检查。
3. 格式化 Go 源码。
4. 执行 `go test ./...` 与 `go vet ./...`。
5. 以 `CGO_ENABLED=0`、`GOOS=windows`、目标 `GOARCH` 和 `-trimpath` 构建隐藏工作流核心。
6. 构建无控制台 AskPass 辅助程序；它只通过当前用户专用随机命名管道接收一次密码请求。
7. 将工作流核心、AskPass 和 XAML 作为资源封装进单文件 WPF GUI EXE，并写入包含 16—256 像素图层的原生 Windows ICO。
8. 离屏渲染首页和操作工作区，并检查两张预览都不是空图。
9. 在 GUI 内实际跑通纯本地操作流程。
10. 启动内嵌核心的必填输入冒烟流程，关闭其标准输入，验证 5 秒内退出且提示只输出一次。
11. 执行带用户访问控制的 AskPass 命名管道冒烟测试。
12. 启动专用隐藏操作核心进入真实面板隧道等待点，实际触发 WPF“关闭面板隧道”按钮点击；必须收到后端确认、进程以 0 退出、GUI 清除隧道状态，同时验证普通输入隐藏且 Y/N 禁用。
13. 用隔离历史文件验证 GUI 的保存、自动回填、删除与清空路径。
14. 输出最终 GUI EXE 的 SHA-256。

构建结果位于 `dist`：

```text
TextNodeAssistant-v0.9.5-win64.exe       默认发布的单文件 GUI
TextNodeAssistant-v0.9.5-win32.exe       Windows 10 x86 单文件 GUI
TextNodeAssistant-v0.9.5-win-arm64.exe   Windows 10/11 ARM64 单文件 GUI
TextNodeAssistant-v0.9.5-cli-win*.exe    构建中间件/高级调试核心
TextNodeAssistant-v0.9.5-askpass-win*.exe 构建中间件/受限命名管道辅助程序
TextNodeAssistant-v0.9.5-gui-preview.png 界面渲染验证图
TextNodeAssistant-v0.9.5-workflow-preview.png 操作工作区渲染验证图
```

应用图标源文件位于 `gui/TextNodeAssistant-v0.9.5-app-icon.png`，Windows 多尺寸资源位于 `gui/TextNodeAssistant-v0.9.5.ico`。Windows 应用与内嵌 Linux runbook 均为 v0.9.5；构建会重新生成 runbook 的 `SHA256SUMS.txt`，并把性能/流量、XHTTP 本地影子、固定 copyparty 私人网盘与 15 套伪装站模板一并打入归档。

Linux Shell 静态语法可在 Git Bash 中执行：

```bash
find runbook/text-node-assistant-v0.9.5/linux -name '*.sh' -print0 | xargs -0 -n1 bash -n
scripts/test-xui-api-context.sh
scripts/test-warp-route-idempotency.sh
scripts/test-deployment-state.sh
scripts/test-private-drive-static.sh
```

Android 测试与正式签名构建：

```powershell
cd android
.\build-android.ps1 -Task Test
.\build-signed-release.ps1
```

正式 APK 输出到 `android/dist/TextNodeAssistant-v0.9.5-android-universal.apk`。为保持已安装用户可原地升级，应用 ID 与既有受保护签名身份属于兼容边界；签名密钥、密码、`local.properties`、Gradle 缓存和构建目录禁止进入源码包。

全平台构建完成后运行 `package.ps1`。它要求三个 Windows EXE 与正式 Android APK 全部存在，生成便携包、源码包、SHA-256 清单和 `TextNodeAssistant-v0.9.5-sbom.spdx.json`。发布环境应先把真实运行数据的换行列表编码为 Base64 并放入 `TNA_PRIVACY_FORBIDDEN_B64`；打包器会在压缩前扫描便携目录和源码目录，命中时直接失败。最终还应解包 ZIP/TAR/APK 再运行同一隐私扫描。

