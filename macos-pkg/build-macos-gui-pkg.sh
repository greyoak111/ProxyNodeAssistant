#!/bin/zsh
# Build the native macOS GUI package. The SwiftUI app provides the day-to-day
# dashboard; the existing CLI is bundled as a resource for advanced actions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/ProxyNodeAssistant-v1.0.0-macos-gui-user.pkg"
PKG_VERSION="1.0.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$ROOT/build"
OUT="$(mktemp -d "$ROOT/build/macos-gui-pkg.XXXXXX")"
trap 'rm -rf -- "$OUT"' EXIT INT TERM
APP="$OUT/payload/Applications/ProxyNodeAssistant.app"
mkdir -p "$OUT/arm64" "$OUT/x86_64" \
  "$APP/Contents/MacOS" "$APP/Contents/Resources" \
  "$OUT/icon.iconset" "$OUT/scripts"

SOURCE_DIR="$ROOT/macos-pkg/sources"
ARM_TAR="$SOURCE_DIR/ProxyNodeAssistant-v1.0.0-cli-darwin-arm64.tar.gz"
X86_TAR="$SOURCE_DIR/ProxyNodeAssistant-v1.0.0-cli-darwin-amd64.tar.gz"
if [[ ! -f "$ARM_TAR" ]]; then
  print -u2 "Missing $ARM_TAR"
  exit 1
fi

tar -xzf "$ARM_TAR" -C "$OUT/arm64"
ARM_BIN="$OUT/arm64/ProxyNodeAssistant-v1.0.0-cli-darwin-arm64"
# Deterministic release archives keep a directory root.  Older local archives
# placed the executable directly at the extraction root, so resolve both
# layouts instead of passing a directory to lipo (which produces the opaque
# "can't map input file" failure).
if [[ ! -f "$ARM_BIN" || ! -x "$ARM_BIN" ]]; then
  ARM_BIN="$(find "$OUT/arm64" -type f -name 'ProxyNodeAssistant-v1.0.0-cli-darwin-arm64' -perm -111 -print -quit)"
fi
if [[ ! -f "$ARM_BIN" || ! -x "$ARM_BIN" ]]; then
  print -u2 "The ARM64 archive did not contain its expected executable."
  exit 1
fi

CLI_BIN="$OUT/ProxyNodeAssistant-cli"
if [[ -f "$X86_TAR" ]]; then
  tar -xzf "$X86_TAR" -C "$OUT/x86_64"
  X86_BIN="$OUT/x86_64/ProxyNodeAssistant-v1.0.0-cli-darwin-amd64"
  if [[ ! -f "$X86_BIN" || ! -x "$X86_BIN" ]]; then
    X86_BIN="$(find "$OUT/x86_64" -type f -name 'ProxyNodeAssistant-v1.0.0-cli-darwin-amd64' -perm -111 -print -quit)"
  fi
  if [[ -f "$X86_BIN" && -x "$X86_BIN" ]]; then
    lipo -create -output "$CLI_BIN" "$ARM_BIN" "$X86_BIN"
  else
    cp "$ARM_BIN" "$CLI_BIN"
  fi
else
  cp "$ARM_BIN" "$CLI_BIN"
fi
chmod 755 "$CLI_BIN"
codesign --force --sign - "$CLI_BIN" >/dev/null

swiftc -O -target arm64-apple-macosx13.0 -sdk "$SDK" \
  -framework SwiftUI -framework AppKit -framework Combine \
  -module-name ProxyNodeAssistant \
  "$ROOT/macos-native/Sources/ProxyNodeAssistantApp.swift" \
  "$ROOT/macos-native/Sources/ContentView.swift" \
  -o "$OUT/ProxyNodeAssistantGUI-arm64"

if swiftc -O -target x86_64-apple-macosx13.0 -sdk "$SDK" \
  -framework SwiftUI -framework AppKit -framework Combine \
  -module-name ProxyNodeAssistant \
  "$ROOT/macos-native/Sources/ProxyNodeAssistantApp.swift" \
  "$ROOT/macos-native/Sources/ContentView.swift" \
  -o "$OUT/ProxyNodeAssistantGUI-x86_64"; then
  lipo -create -output "$APP/Contents/MacOS/ProxyNodeAssistant" \
    "$OUT/ProxyNodeAssistantGUI-arm64" "$OUT/ProxyNodeAssistantGUI-x86_64"
else
  cp "$OUT/ProxyNodeAssistantGUI-arm64" "$APP/Contents/MacOS/ProxyNodeAssistant"
fi
chmod 755 "$APP/Contents/MacOS/ProxyNodeAssistant"

cp "$CLI_BIN" "$APP/Contents/Resources/ProxyNodeAssistant-cli"
ICON_ASSET="$ROOT/ProxyNodeAssistant-v1.0.0-app-icon.png"
if [[ ! -f "$ICON_ASSET" ]]; then
  ICON_ASSET="$ROOT/macos-native/Resources/ProxyNodeAssistant-v1.0.0-app-icon.png"
fi
if [[ ! -f "$ICON_ASSET" ]]; then
  print -u2 "Missing the ProxyNodeAssistant v1.0.0 icon asset."
  exit 1
fi
cp "$ICON_ASSET" "$APP/Contents/Resources/ProxyNodeAssistant-v1.0.0-app-icon.png"
chmod 755 "$APP/Contents/Resources/ProxyNodeAssistant-cli"

# Remote SSH operations need a real controlling terminal for OpenSSH's
# password prompt.  The small relay uses forkpty and unbuffered read/write,
# avoiding the macOS `script` stdout buffering seen when a GUI app launches it.
clang -O2 -target arm64-apple-macos13.0 -isysroot "$SDK" \
  "$ROOT/macos-native/Resources/pna-pty-bridge.c" \
  -o "$OUT/pna-pty-bridge-arm64"
if clang -O2 -target x86_64-apple-macos13.0 -isysroot "$SDK" \
    "$ROOT/macos-native/Resources/pna-pty-bridge.c" \
    -o "$OUT/pna-pty-bridge-x86_64"; then
  lipo -create -output "$APP/Contents/Resources/pna-pty-bridge" \
    "$OUT/pna-pty-bridge-arm64" "$OUT/pna-pty-bridge-x86_64"
else
  cp "$OUT/pna-pty-bridge-arm64" "$APP/Contents/Resources/pna-pty-bridge"
fi
chmod 755 "$APP/Contents/Resources/pna-pty-bridge"
codesign --force --sign - "$APP/Contents/Resources/pna-pty-bridge" >/dev/null

ICON_SOURCE="$ICON_ASSET"
if [[ -f "$ICON_SOURCE" ]]; then
  for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$ICON_SOURCE" --out "$OUT/icon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -s format png -z "$double" "$double" "$ICON_SOURCE" --out "$OUT/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$OUT/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>ProxyNodeAssistant</string>
  <key>CFBundleExecutable</key><string>ProxyNodeAssistant</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.greyoak111.proxynodeassistant</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ProxyNodeAssistant</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Resources/README-macOS.txt" <<'README'
ProxyNodeAssistant v1.0.0 for macOS

这是原生 SwiftUI 图形化控制台：总览、节点、施工计划、安全日志与设置都在窗口内完成。
连接表单会按 CLI 的真实提示顺序自动提交认证方式、主机、用户和端口；临时密码模式只建立本次一次性会话 key，操作结束、失败、取消或中断都会撤销远端临时公钥并删除本机临时 key。可选的 VPS 登录密码/首次绑定密码只留在本次进程内存，CLI 发出真实 SSH 密码提示时自动提交，留空时可在下方遮罩框输入。长期 key 首次密码验证成功后，GUI 自动确认绑定当前 VPS 主机 + SSH 用户，后续操作直接复用该范围的 key。SSH 握手成功后总览显示真实主机，认证拒绝会明确显示“认证失败”。
长期 SSH key 由 CLI 按 VPS 主机 + SSH 用户分别管理，支持多节点、多用户、多把 key；总览可新增 key，列出后每条绑定都有独立解绑入口；“面板与访问”中的“管理已绑定 key”会打开真实的 [K] 查看、恢复和归档流程，不读取或覆盖私钥。
[12] 清空剪贴板、[14] 本地 10808、[T] 服务商流量中心、[H] 登录历史和 [K] 多 key 管理均只作用于本机；[14] 会把 HTTP/HTTPS/SOCKS 系统代理切到 127.0.0.1:10808 并关闭 PAC/WPAD，同时保存原设置供恢复；它们的工作区不会展示 VPS/SSH 字段，也不会建立 SSH 连接。
[7] 凭据交接单先通过 macOS pbcopy 写入本机剪贴板，再由 pbpaste 回读校验；复制后 GUI 会显示可见的 Y/N 清空确认，先粘贴到密码管理器再选择清空，120 秒无人操作会自动清理。
打开 3x-ui 后，工作区标题栏和输入区会显示“关闭面板隧道”；点击后提交 CLI 保持提示要求的空行，收到 PNA_GUI_TUNNEL_CLOSE_ACK（兼容 TNA_GUI_TUNNEL_CLOSE_ACK）才确认关闭，超时会自动走安全停止并完成临时凭据清理。
真正的远端施工仍由随应用附带的 CLI 执行，但提示、密码和日志均在当前窗口内完成。
macOS 每项远端操作会使用短期的 OpenSSH 控制会话复用首个认证连接；面板转发通过同一条已验证控制会话的 ssh -O forward 创建、ssh -O cancel 关闭，并在点击“关闭面板隧道”后一起回收，避免刚认证成功就再次建立连接触发 VPS 限流。
非交互 SSH/SCP/Host key 探测有 30 秒进程级截止时间；远端不响应时会显示失败诊断并结束当前操作，不会把界面留在“运行中”。
本包是用户级安装包，应用会放在当前用户的 ~/Applications，可直接拖入废纸篓或使用设置中的卸载；若 [14] 留有系统代理恢复快照，卸载会先调用 macOS 自己的授权框恢复快照，确认成功后才删除应用与本地数据。
README

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$OUT/payload"
fi
# macOS can materialise AppleDouble sidecar files (._*) when an input carries
# a resource fork or Finder metadata.  They are not application resources and
# would otherwise be installed beside the app, where uninstallers report them
# as unexplained leftovers.  Strip only sidecars from our private staging tree
# before pkgbuild; never touch the user's existing files.
find "$OUT/payload" -type f \( -name '._*' -o -name '.__*' \) -delete
codesign --force --deep --sign - "$APP" >/dev/null
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$OUT/payload"
fi
find "$OUT/payload" -type f \( -name '._*' -o -name '.__*' \) -delete

cat > "$OUT/components.plist" <<'COMPONENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key><true/>
    <key>BundleIsRelocatable</key><false/>
    <key>BundleIsVersionChecked</key><true/>
    <key>BundleOverwriteAction</key><string>upgrade</string>
    <key>RootRelativeBundlePath</key><string>Applications/ProxyNodeAssistant.app</string>
  </dict>
</array>
</plist>
COMPONENTS

[[ ! -e "$PKG" ]] || unlink "$PKG"
COMPONENT="$OUT/ProxyNodeAssistant-component.pkg"
pkgbuild \
  --root "$OUT/payload" \
  --component-plist "$OUT/components.plist" \
  --identifier com.greyoak111.proxynodeassistant \
  --version "$PKG_VERSION" \
  --install-location / \
  --ownership recommended \
  "$COMPONENT"

cat > "$OUT/Product.dist" <<'DIST'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>ProxyNodeAssistant</title>
  <options customize="never" require-scripts="false"/>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
  <choices-outline>
    <line choice="default"/>
  </choices-outline>
  <choice id="default" visible="false">
    <pkg-ref id="com.greyoak111.proxynodeassistant"/>
  </choice>
  <pkg-ref id="com.greyoak111.proxynodeassistant" version="1.0.0" onConclusion="none">ProxyNodeAssistant-component.pkg</pkg-ref>
</installer-gui-script>
DIST

productbuild \
  --distribution "$OUT/Product.dist" \
  --package-path "$OUT" \
  "$PKG"

printf 'Created %s\n' "$PKG"
printf 'App architectures: %s\n' "$(lipo -archs "$APP/Contents/MacOS/ProxyNodeAssistant" 2>/dev/null || file "$APP/Contents/MacOS/ProxyNodeAssistant")"
