# ProxyNodeAssistant macOS 使用说明（v1.0.0）

## 下载与安装

在 [GitHub v1.0.0 Release](https://github.com/greyoak111/ProxyNodeAssistant/releases/tag/v1.0.0) 下载：

ProxyNodeAssistant-v1.0.0-macos-gui-user.pkg

这是原生 SwiftUI GUI，按 Windows 正式 GUI 的实际操作结构实现七组工作区和 26 个操作。CLI 只是随应用放在 Contents/Resources 内的执行组件；提示、秘密输入、日志和安全停止都由当前窗口承接，不会另开 Terminal。

安装包只允许当前用户域（macOS Installer 的 CurrentUserHomeDirectory），应用安装到：

    ~/Applications/ProxyNodeAssistant.app

安装不需要管理员权限，也不会写入：

- /Applications
- /usr/local/bin/pna
- /usr/local/bin/proxynodeassistant
- 任何系统级安装收据

如果 Finder 没有在侧边栏显示它，按 Command + Shift + G 输入 ~/Applications，双击 ProxyNodeAssistant.app；也可以用 Spotlight 搜索 ProxyNodeAssistant。

## 无管理员完整卸载

先退出应用，然后任选一种方式：

1. 在应用内打开“设置” → “无管理员卸载”；
2. 把 ~/Applications/ProxyNodeAssistant.app 拖到废纸篓。

卸载器只处理当前用户可写的应用范围，并清理：

- ~/Library/Application Support/ProxyNodeAssistant
- ~/Library/Caches/com.greyoak111.proxynodeassistant
- ~/Library/Logs/ProxyNodeAssistant
- ~/Library/Saved Application State/com.greyoak111.proxynodeassistant.savedState
- ~/Library/Preferences/com.greyoak111.proxynodeassistant.plist
- 当前用户卷上的 com.greyoak111.proxynodeassistant 收据

卸载后可在 Finder 的“前往文件夹…”打开 ~/Applications，确认应用已不存在；不需要输入管理员密码。它不会触碰其他应用或系统目录。

## 包体校验

SHA-256  1326bc5cec557b9235c9307cb986dd7ab34c5a258b14e3679d1098c3b83a1328
文件名   ProxyNodeAssistant-v1.0.0-macos-gui-user.pkg

安装包由 arm64 与 x86_64 通用 GUI 和同架构 CLI 组成。当前发布构建已验证：

- installer -dominfo -plist 仅包含 CurrentUserHomeDirectory；
- 应用主二进制 lipo -archs 为 x86_64 arm64；
- 应用仅链接系统 SwiftUI / AppKit / Combine 等框架；
- 安装后文件归当前用户所有；
- 设置页卸载与直接移除应用都不需要管理员权限；
- 卸载后应用、用户配置、日志、缓存和用户级收据均可清理。

## 从源构建

构建机需要 macOS 13+、Xcode Command Line Tools、swiftc、pkgbuild、productbuild、lipo、codesign 和图标工具。项目内的 macos-pkg/build-macos-gui-pkg.sh 会：

1. 读取项目根目录的 v1.0.0 Darwin CLI 压缩包；
2. 组装通用 CLI；
3. 编译 arm64 / x86_64 SwiftUI GUI；
4. 生成用户级 product package；
5. 退出时自动清理 build/macos-gui-pkg.* 中间目录。

    chmod 755 macos-pkg/build-macos-gui-pkg.sh
    ./macos-pkg/build-macos-gui-pkg.sh

兼容入口 macos-pkg/build-macos-pkg.sh 会转发到同一 GUI 构建脚本。不要把旧的系统级安装脚本、全局 CLI 或 Terminal 包装器重新放回发布目录。

## 安全边界

所有真实远端变更仍由 CLI 的失败即停、先预览、先备份和精确确认流程负责。GUI 不会预填节点、线路或“健康分数”，未连接时显示 LOCAL::FAIL_CLOSED；密码使用遮罩输入，不写入命令行参数、日志或磁盘。
