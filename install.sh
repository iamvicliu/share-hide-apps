#!/bin/bash
# 共享时隐身 —— 一键安装
# 屏幕被采集（会议共享 / 录屏 / 部分截图）时，自动隐藏你指定的应用。
# 源码与说明：https://github.com/iamvicliu/share-hide-apps
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/iamvicliu/share-hide-apps/main"
APP_SUPPORT="$HOME/Library/Application Support/ShareHideApps"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
APPS_DIR="$HOME/Applications"
BIN="$APP_SUPPORT/sharewatch"
WRAPPER="$APP_SUPPORT/共享时隐身"
PLIST="$LAUNCH_DIR/com.sharehideapps.agent.plist"
LOG="$LOG_DIR/ShareHideApps.log"
LABEL="com.sharehideapps.agent"
CONFIG="$APP_SUPPORT/apps.conf"
CONFIG_APP="$APPS_DIR/共享时隐身.app"

echo "==> 安装「共享时隐身」"
mkdir -p "$APP_SUPPORT" "$LAUNCH_DIR" "$LOG_DIR" "$APPS_DIR"

echo "==> 下载后台程序"
curl -fsSL --retry 3 --retry-delay 2 "$REPO_RAW/sharewatch" -o "$BIN"
chmod +x "$BIN"
xattr -dr com.apple.quarantine "$BIN" 2>/dev/null || true
if ! lipo -info "$BIN" >/dev/null 2>&1; then
  echo "后台程序下载失败，安装中止。" >&2
  exit 1
fi

echo "==> 下载配置程序"
mkdir -p "$CONFIG_APP/Contents/MacOS"
mkdir -p "$CONFIG_APP/Contents/Resources"
curl -fsSL --retry 3 --retry-delay 2 "$REPO_RAW/AppIcon.icns" -o "$CONFIG_APP/Contents/Resources/AppIcon.icns"
curl -fsSL --retry 3 --retry-delay 2 "$REPO_RAW/hideapps-config" -o "$CONFIG_APP/Contents/MacOS/hideapps-config"
chmod +x "$CONFIG_APP/Contents/MacOS/hideapps-config"
cat > "$CONFIG_APP/Contents/Info.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>hideapps-config</string>
    <key>CFBundleIdentifier</key><string>com.sharehideapps.config</string>
    <key>CFBundleName</key><string>共享时隐身</string>
    <key>CFBundleDisplayName</key><string>共享时隐身</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST_EOF
xattr -dr com.apple.quarantine "$CONFIG_APP" 2>/dev/null || true
codesign -s - --force --deep "$CONFIG_APP" >/dev/null 2>&1 || true

echo "==> 生成配置文件（默认不隐藏任何应用，由你自己添加）"
if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<'CONF_EOF'
# 共享 / 录屏 / 截图时要隐藏的应用，每行一个。
# 写 bundle id 或应用名；# 后面是备注。推荐用「共享时隐身」配置窗口管理。
# 例：com.tencent.xinWeChat   # 微信
CONF_EOF
fi

echo "==> 生成后台启动项"
cat > "$WRAPPER" <<WRAP_EOF
#!/bin/bash
exec "$BIN"
WRAP_EOF
chmod +x "$WRAPPER"

cat > "$PLIST" <<PLIST_EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$WRAPPER</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST_EOF2
plutil -lint "$PLIST" >/dev/null

echo "==> 启动后台"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout 是异步的：等旧服务真正退出再启动，否则 bootstrap 可能报 I/O 错误
for _ in $(seq 1 20); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
for _ in 1 2 3; do
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break
  sleep 1
done
if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo "后台启动失败，请重新运行安装命令。日志：$LOG" >&2
  exit 1
fi

echo "==> 打开配置窗口"
open "$CONFIG_APP"

echo ""
echo "✅ 安装完成，后台已运行、开机自启。"
echo "   在刚弹出的「共享时隐身」窗口里，把要隐藏的应用加进去即可（即时生效）。"
echo "   配置程序：$CONFIG_APP （以后随时打开管理）"
echo "   日志：$LOG"
echo "   卸载：curl -fsSL $REPO_RAW/uninstall.sh | bash"
echo "   提示：任何录屏 / 截图 / 会议共享都会触发隐藏；需要时点 Dock 图标恢复。"
