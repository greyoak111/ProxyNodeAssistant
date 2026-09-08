# ProxyNodeAssistant v1.0.0 构建、验证与发行

本文只描述当前的 **v1.0.0 精简重置线**。它以 v0.9.0 的可靠 SSH 运维主链路为基础，已经退役此前实验版引入的本机 admin/恢复门禁、UI 门禁、设备身份/准入、controller、邀请、租约和网盘。构建产物不得重新暴露这些入口；登录只使用普通 SSH 密码或长期 key，完整远端凭据交接仍必须保留并验证。

## 1. 版本与目录基线

- 产品名：`ProxyNodeAssistant`
- 对外版本：`1.0.0`
- Windows GUI：`dist/ProxyNodeAssistant-v1.0.0-*.exe`
- Linux 工具包目录：`runbook/proxy-node-assistant-v1.0.0`
- Linux 工具包归档：`assets/proxy-node-assistant-toolkit-v1.0.0.tar.gz`
- Android APK：`android/dist/ProxyNodeAssistant-v1.0.0-android-universal.apk`

应用、内嵌工具包、Android 资产和发行说明必须同时来自同一次源码状态。不要用旧 v0.9.0 EXE、旧过度版 v1.0.0 工具包或手工替换过的归档拼装发行包。

## 2. Windows 构建环境

需要：

- Windows 10/11；
- PowerShell 5.1 或更新版本；
- Go 1.23 或更新版本；
- Python 3.9 或更新版本（仅使用标准库，用于生成确定性 `tar.gz` 归档）；
- Windows 自带 `tar.exe`；
- .NET Framework 4.x 的 C# 编译器和 WPF 程序集；
- Git Bash 或其他可运行 Bash 的环境，用于 Shell 静态测试；
- 构建 Android 时还需要 JDK 17、Gradle 和 Android SDK。加 `-Provision` 后，Android 脚本会在项目内的 `.android-tools` 中准备受控工具链。

`scripts/ensure-go.ps1` 可用于查找或准备 Go。构建脚本也支持现有的 `PNA_GO_EXE`、`PNA_GOFMT_EXE`、`PNA_BASH_EXE`、`PNA_CSC_EXE` 和 `PNA_PYTHON_EXE` 环境覆盖；这些 `PNA_*` 名称仅是兼容实现细节，不是产品名。

## 3. 推荐：一次构建全部正式产物

在仓库根目录运行或双击：

```text
build-all-pc.bat
```

它按顺序完成：

1. 构建并完整验证 Windows x64；
2. 构建并验证 Windows x86；
3. 交叉编译 Windows ARM64，并在非 ARM64 构建机上只做静态校验；
4. 构建、对齐、签名并验证 Android 通用 APK；
5. 运行 `package.ps1`，生成便携包、源码包、说明书和 SHA-256 清单。

默认正式发行目录是：

```text
outputs/ProxyNodeAssistant-v1.0.0-official
```

批处理标题和目标文件必须明确显示 `ProxyNodeAssistant v1.0.0 reset line`。如果本地还有写着 `ProxyNodeAssistant v0.9.0` 的旧批处理副本，不要使用。

## 4. 分架构构建

需要逐项排障时，在仓库根目录运行：

```powershell
# Windows x64：执行公共验证和本机运行时冒烟
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Architecture amd64

# Windows x86：复用已完成的公共验证，仍执行可运行的本机冒烟
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Architecture 386 -SkipCommonValidation

# Windows ARM64：在 x64 构建机上交叉编译和静态校验
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Architecture arm64 -SkipCommonValidation -SkipRuntimeSmoke
```

x86 二进制可在兼容的 x64 Windows 上真实运行验证。ARM64 二进制只有在 ARM64 Windows 上执行才算运行时验证；x64 构建机不得把交叉编译报告成“已原生跑通”。

## 5. `build.ps1` 的验证内容

首次架构构建会：

1. 重建 `runbook/proxy-node-assistant-v1.0.0/SHA256SUMS.txt`；
2. 重建 `assets/proxy-node-assistant-toolkit-v1.0.0.tar.gz`；
3. 执行以下 Bash 校验：

   ```text
   scripts/validate-shell.sh
   scripts/test-diagnosis-protocol.sh
   scripts/test-xui-api-context.sh
   scripts/test-warp-route-idempotency.sh
   scripts/test-gui-remote-prompt.sh
   ```

4. 执行以下 PowerShell 静态校验：

   ```text
   scripts/test-feature-retirement-static.ps1
   scripts/test-reset-core-install-modes-static.ps1
   scripts/test-android-reset-static.ps1
   ```

5. 对根目录 Go 源码执行 `gofmt`；
6. 执行 `go test ./...` 和 `go vet ./...`；
7. 以 `CGO_ENABLED=0`、`GOOS=windows`、目标 `GOARCH` 和 `-trimpath` 构建核心与 AskPass；
8. 通过当前用户专用随机命名管道验证 AskPass；
9. 将核心、AskPass、XAML 和图标封装进单文件 WPF GUI；
10. 执行首页/工作区离屏渲染、工作流、输入关闭、面板隧道生命周期和历史记录冒烟测试；
11. 输出 GUI EXE 的 SHA-256。

构建失败必须原样处理为失败；不要通过删除测试、吞掉退出码或复制旧产物绕过。

## 6. Windows 构建结果

结果位于 `dist`：

```text
ProxyNodeAssistant-v1.0.0-win64.exe
ProxyNodeAssistant-v1.0.0-win32.exe
ProxyNodeAssistant-v1.0.0-win-arm64.exe
ProxyNodeAssistant-v1.0.0-cli-win64.exe
ProxyNodeAssistant-v1.0.0-cli-win32.exe
ProxyNodeAssistant-v1.0.0-cli-win-arm64.exe
ProxyNodeAssistant-v1.0.0-askpass-win64.exe
ProxyNodeAssistant-v1.0.0-askpass-win32.exe
ProxyNodeAssistant-v1.0.0-askpass-win-arm64.exe
ProxyNodeAssistant-v1.0.0-gui-preview.png
ProxyNodeAssistant-v1.0.0-workflow-preview.png
```

对外发布前三个 GUI EXE；`cli` 和 `askpass` 是构建/高级排障中间件，不作为普通用户入口。

## 7. macOS / Linux CLI 构建

macOS 与 Linux 提供同一套无 GUI 的 CLI 工作流（SSH、诊断、SS2022 白名单等）。
在 Windows 构建机上可交叉编译四个目标：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-unix.ps1
```

也可以只构建一个系统或架构：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-unix.ps1 -Target linux -Architecture arm64
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-unix.ps1 -Target darwin -Architecture amd64
```

产物位于 `dist/ProxyNodeAssistant-v1.0.0-cli-<os>-<arch>`，同时生成对应 `.tar.gz` 和 `SHA256SUMS-unix-v1.0.0.txt`。归档由 `scripts/create_deterministic_tar.py` 生成：gzip 与 TarInfo 的时间固定为 epoch 0，属主固定为 `root:root`，目录和脚本/二进制使用 `0755`（普通资料使用 `0644`）；构建脚本会立即复核这些模式。这样从 Windows 构建机生成的包在 Linux/macOS 解包后可直接执行。 这些 CLI 不携带 WPF/AskPass；运行主机需自行安装 `ssh`、`scp`、`ssh-keygen`、`ssh-keyscan`。Darwin 的 `[14]` 管理 macOS 系统级 HTTP/HTTPS/SOCKS 代理 `127.0.0.1:10808`，同时关闭 PAC/WPAD；配置前保存系统代理、撤销或恢复时还原原设置，必要时请求 macOS 管理员授权，且不连接 VPS；Linux 的 `[14]` 只影响本工具及其子进程的环境，不能替父 shell 持久修改变量。

Unix 凭据与交互边界：macOS 使用系统 Keychain 的 `security`，Linux 使用 Secret Service 的 `secret-tool`；若命令或后台不可用，菜单会返回带安装提示的明确错误，不会回退到明文文件。Linux 写入通过 `secret-tool` 的标准输入传递秘密；macOS `security` 的非交互写入接口只有 `-w` 参数，工具不会把它写入日志或文件，但该系统 CLI 本身可能在短暂进程参数中暴露值，单用户本机使用更合适。Unix 终端秘密提示通过 `/dev/tty` 配合 `stty -echo`/`stty echo`，读取结束或出错都会恢复回显。

### 7.1 macOS 原生 GUI 用户包

原生桌面包由 SwiftUI 界面、同一 revision 的 Darwin CLI 和 `forkpty` 终端桥组成。它必须保持对外版本 `1.0.0`，并在当前用户目录安装：

```zsh
chmod 755 macos-pkg/build-macos-gui-pkg.sh
macos-pkg/build-macos-gui-pkg.sh
installer -pkg ProxyNodeAssistant-v1.0.0-macos-gui-user.pkg \
  -target CurrentUserHomeDirectory
open ~/Applications/ProxyNodeAssistant.app
```

构建脚本会编译 `arm64` 与 `x86_64`（可用时合并为 universal）GUI、CLI 和 PTY bridge，写入用户级 component package，并验证 bundle 版本、架构、代码签名和 AppleDouble sidecar 清理。安装不会创建系统级 `/Applications`、`/usr/local/bin` 或管理员收据；设置中的卸载路径也只作用于当前用户。

`[7]` 凭据交接验收必须分别针对每一台测试 VPS 执行。验收步骤是：在 GUI 中完成真实 SSH key/密码流程，看到“已复制到系统剪贴板”后按保存提示确认；CLI 会用 `pbpaste` 回读并在内存中按字节核对，测试脚本只检查非空、字节数、`REQUIRED LOGIN CREDENTIALS`/`VPS_ACCOUNT`/`VPS_PASSWORD`/`PANEL_ACCOUNT`/`PANEL_PASSWORD` 等标记，不打印任何值；完成粘贴后选择清空，或运行本地 `[12]`。GUI 的清空提示由用户明确选择，未操作时只在有限安全超时后清理，不能让交接单在复制瞬间消失。

Darwin 源归档只放在 `macos-pkg/sources/` 作为可复现构建输入；GitHub Release 对普通用户提供上述 `.pkg`，不再把半成品 Darwin CLI 压缩包当作 macOS 桌面入口。`.pkg` 是发行资产，不提交到源码仓库；发布时同时更新根目录的 `SHA256SUMS-macos-pkg-gui-user.txt` 和 release 说明。

图标源文件：

```text
gui/ProxyNodeAssistant-v1.0.0-app-icon.png
gui/ProxyNodeAssistant-v1.0.0.ico
```

## 8. Android 构建与签名

在仓库根目录运行：

```powershell
# 单元测试/调试构建
powershell -NoProfile -ExecutionPolicy Bypass -File .\android\build-android.ps1 -Task Test -Provision
powershell -NoProfile -ExecutionPolicy Bypass -File .\android\build-android.ps1 -Task Debug -Provision

# 正式签名 APK
powershell -NoProfile -ExecutionPolicy Bypass -File .\android\build-signed-release.ps1 -Provision
```

正式结果：

```text
android/dist/ProxyNodeAssistant-v1.0.0-android-universal.apk
```

Android 构建会核对内嵌工具包版本、内部 revision、顶层目录、必要安装入口和归档 SHA-256，避免 APK 携带旧工具包。

### Android 签名兼容边界

以下旧名称必须原样保留：

```text
%LOCALAPPDATA%\ProxyNodeAssistant\android-signing
pna-release-v1.jks
pna-release-v1
既有证书 DN
pna-v0.9.0-vault
```

它们仅是 Android 原位升级签名和旧加密数据解密的兼容边界，不影响当前产品名 `ProxyNodeAssistant`。改名、删除或重建签名身份会使已安装 APK 无法原位升级；改动 vault alias 会使旧加密数据不可读。应离线备份 keystore 及其 DPAPI 密码文件，不得提交仓库。

## 9. 发行打包

先完成三种 Windows GUI 与已签名 Android APK，再运行：

```powershell
$env:PNA_PACKAGE_OUTPUT = (Join-Path $PWD 'outputs\ProxyNodeAssistant-v1.0.0-official')
powershell -NoProfile -ExecutionPolicy Bypass -File .\package.ps1
Remove-Item Env:PNA_PACKAGE_OUTPUT
```

`package.ps1` 会拒绝缺少 EXE、APK、工具包、预览图、图标或说明书的半成品发行。正式目录包含：

```text
ProxyNodeAssistant-v1.0.0-win64.exe
ProxyNodeAssistant-v1.0.0-win32.exe
ProxyNodeAssistant-v1.0.0-win-arm64.exe
ProxyNodeAssistant-v1.0.0-android-universal.apk
proxy-node-assistant-toolkit-v1.0.0.tar.gz
ProxyNodeAssistant-v1.0.0-便携包.zip
ProxyNodeAssistant-v1.0.0-source.zip
ProxyNodeAssistant-v1.0.0-完整使用说明书.md
ProxyNodeAssistant-v1.0.0-从零部署教程.md
ProxyNodeAssistant-v1.0.0-更新说明.md
ProxyNodeAssistant-v1.0.0-android-manual-zh-CN.md
ProxyNodeAssistant-v1.0.0-gui-preview.png
ProxyNodeAssistant-v1.0.0-workflow-preview.png
ProxyNodeAssistant-v1.0.0-app-icon.png
ProxyNodeAssistant-v1.0.0.ico
SHA256SUMS-v1.0.0.txt
SHA256SUMS-GITHUB-v1.0.0.txt
```

GitHub 发布时，中文文件会使用 `portable.zip`、`release-notes-zh-CN.md`、`beginner-guide-zh-CN.md` 和 `manual-zh-CN.md` 等 ASCII 映射；以 `SHA256SUMS-GITHUB-v1.0.0.txt` 为准。

## 10. 旧内部名称

源码仍可能出现以下兼容实现名：

- WPF 内嵌资源键 `ProxyNodeAssistant.*`；
- Go module 名 `proxynodeassistant`；
- `PNA_*` 环境变量；
- 上述 Android 签名目录、alias、DN 与 vault alias。

这些不是对外产品名，也不表示旧功能仍存在。资源键和标识符只有在确认不会破坏资源装载、升级签名、既有密钥或旧加密数据后才能迁移。用户可见标题、文件名、目录、说明书和新远端工具包必须统一为 `ProxyNodeAssistant v1.0.0`。

## 11. 发行前检查表

- [ ] `go test ./...`、`go vet ./...` 和全部静态脚本通过；
- [ ] x64/x86 运行时冒烟通过，ARM64 的验证范围如实标注；
- [ ] Android 单元测试、签名和 `apksigner verify` 通过；
- [ ] APK 内工具包和独立工具包来自同一 revision；
- [ ] GUI/Android 不再显示本机 admin/恢复、UI 门禁、远端设备身份/准入、controller、邀请、租约或网盘入口；登录只使用普通 SSH 密码或长期 key；
- [ ] 菜单 `[1]` 是唯一施工入口，并保留每项 SSH 临时密码/绑定 key 双模式；
- [ ] 安装模式必须显式选择：已有节点才允许 `0 keep`，以及 `1 灰云 / 2 橙云 / 3 双路`；
- [ ] 预览后必须输入精确 `APPLY` 才能上传或改远端；
- [ ] 无任何真实 VPS IP、域名、邮箱、密码、私钥、API key 或本机运行态凭据进入源码和发行包；
- [ ] `SHA256SUMS-v1.0.0.txt` 与 `SHA256SUMS-GITHUB-v1.0.0.txt` 都能校验对应文件；
- [ ] 在干净目录解压便携包和源码包，再做一次名称、隐私和启动抽查。
