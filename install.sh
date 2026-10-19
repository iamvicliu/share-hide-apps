#!/bin/bash
# 共享时隐身 —— 一键安装
# 屏幕被采集（会议共享 / 录屏）时，自动隐藏你指定的应用。
# 源码与说明：https://github.com/iamvicliu/share-hide-apps
set -euo pipefail

REPO_RAW="${SHAREHIDE_REPO_RAW:-https://raw.githubusercontent.com/iamvicliu/share-hide-apps/main}"
APP_SUPPORT="$HOME/Library/Application Support/ShareHideApps"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
APPS_DIR="$HOME/Applications"
APP="$APPS_DIR/共享时隐身.app"
BIN="$APP/Contents/MacOS/ShareHideApps"
PLIST="$LAUNCH_DIR/com.sharehideapps.agent.plist"
LOG="$LOG_DIR/ShareHideApps.log"
LABEL="com.sharehideapps.agent"
CONFIG="$APP_SUPPORT/apps.conf"

echo "==> 安装「共享时隐身」"
mkdir -p "$APP_SUPPORT" "$LAUNCH_DIR" "$LOG_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 停止正在运行的旧版本"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout 是异步的：等旧服务真正退出再继续，否则之后 bootstrap 可能报 I/O 错误
for _ in $(seq 1 20); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
pkill -x ShareHideApps 2>/dev/null || true
pkill -x hideapps-config 2>/dev/null || true

echo "==> 下载程序"
# 先下载到临时文件再 mv 替换：直接覆盖正在运行的程序会让系统判定签名失效，
# 之后读取它的进程（如 lipo）会被杀掉，升级安装因此失败。
curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors "$REPO_RAW/ShareHideApps" -o "$BIN.new"
chmod +x "$BIN.new"
if ! lipo -info "$BIN.new" >/dev/null 2>&1; then
  rm -f "$BIN.new"
  echo "程序下载失败，安装中止。" >&2
  exit 1
fi
mv -f "$BIN.new" "$BIN"
curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors "$REPO_RAW/AppIcon.icns" -o "$APP/Contents/Resources/AppIcon.icns"

# 1.1.x 及更早是两个程序（后台 sharewatch + 配置窗口 hideapps-config），现在合成一个，清掉旧文件。
rm -f "$APP/Contents/MacOS/hideapps-config" \
      "$APP_SUPPORT/sharewatch" "$APP_SUPPORT/共享时隐身" "$APP_SUPPORT/共享隐身"

# LSUIElement：平时只在菜单栏显示图标，打开配置窗口时才出现在 Dock。
cat > "$APP/Contents/Info.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ShareHideApps</string>
    <key>CFBundleIdentifier</key><string>com.sharehideapps.app</string>
    <key>CFBundleName</key><string>共享时隐身</string>
    <key>CFBundleDisplayName</key><string>共享时隐身</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>个别应用（如 Telegram）不响应普通隐藏，需要通过「系统事件」把它隐藏。</string>
</dict>
</plist>
PLIST_EOF
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign -s - --force --deep "$APP" >/dev/null 2>&1 || true

echo "==> 生成配置文件（默认不隐藏任何应用，由你自己添加）"
if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<'CONF_EOF'
# 共享 / 录屏时要隐藏的应用，每行一个。
# 写 bundle id 或应用名；# 后面是备注。推荐用「共享时隐身」配置窗口管理。
# 例：com.tencent.xinWeChat   # 微信
CONF_EOF
fi

echo "==> 设置开机自启"
# --background：登录时只显示菜单栏图标，不弹配置窗口。
# 日志由程序自己写，这里不重定向，避免每行写两遍。
cat > "$PLIST" <<PLIST_EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string><string>--background</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
PLIST_EOF2
plutil -lint "$PLIST" >/dev/null

echo "==> 启动"
STARTS_BEFORE=$(grep -c "启动（" "$LOG" 2>/dev/null || true)
for _ in 1 2 3; do
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break
  sleep 1
done
if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo "启动失败，请重新运行安装命令。日志：$LOG" >&2
  exit 1
fi
# 等开机自启的那份拿到单实例锁（日志多出一行「启动」）再打开窗口，让窗口由它来弹。
# 新装的程序第一次启动要做签名检查，可能慢好几秒，太早 open 会让新起的那份抢到锁。
for _ in $(seq 1 30); do
  [ "$(grep -c "启动（" "$LOG" 2>/dev/null || true)" -gt "${STARTS_BEFORE:-0}" ] && break
  sleep 0.5
done
open "$APP"

echo ""
echo "✅ 安装完成，已运行、开机自启，菜单栏右上角有个眼睛图标。"
echo "   在刚弹出的「共享时隐身」窗口里，把要隐藏的应用加进去即可（即时生效）。"
echo "   关掉窗口程序照常工作；以后点菜单栏图标「打开配置…」或打开 $APP 管理。"
echo "   日志：$LOG"
echo "   卸载：curl -fsSL $REPO_RAW/uninstall.sh | bash"
echo "   提示：任何录屏 / 会议共享都会触发隐藏；需要时点 Dock 图标恢复。"
