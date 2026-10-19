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

# 提示语跟随系统首选语言：中文显示中文，其他显示英文。
case "$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | tr -d ' ",')" in
  zh*) ZH=1 ;;
  *) ZH=0 ;;
esac
msg() { if [ "$ZH" = 1 ]; then echo "$1"; else echo "$2"; fi; }

msg "==> 安装「共享时隐身」" "==> Installing ShareHide"
mkdir -p "$APP_SUPPORT" "$LAUNCH_DIR" "$LOG_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || pgrep -x ShareHideApps >/dev/null || pgrep -x hideapps-config >/dev/null; then
  msg "==> 停止正在运行的旧版本" "==> Stopping the running version"
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout 是异步的：等旧服务真正退出再继续，否则之后 bootstrap 可能报 I/O 错误
for _ in $(seq 1 20); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
pkill -x ShareHideApps 2>/dev/null || true
pkill -x hideapps-config 2>/dev/null || true

msg "==> 下载程序" "==> Downloading"
# 先下载到临时文件再 mv 替换：直接覆盖正在运行的程序会让系统判定签名失效，
# 之后读取它的进程（如 lipo）会被杀掉，升级安装因此失败。
curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors "$REPO_RAW/ShareHideApps" -o "$BIN.new"
chmod +x "$BIN.new"
if ! lipo -info "$BIN.new" >/dev/null 2>&1; then
  rm -f "$BIN.new"
  msg "程序下载失败，安装中止。" "Download failed. Installation stopped." >&2
  exit 1
fi
mv -f "$BIN.new" "$BIN"
# 图标下载失败不影响使用，提示一句继续装
if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors "$REPO_RAW/AppIcon.icns" -o "$APP/Contents/Resources/AppIcon.icns"; then
  rm -f "$APP/Contents/Resources/AppIcon.icns"
  msg "⚠️  图标下载失败，程序照常可用，只是暂时没有图标；之后重新运行安装命令即可补上。" \
      "⚠️  Couldn't download the icon. ShareHide works fine without it; run the install command again to add it." >&2
fi
# 勿扰快捷指令（配置窗口里「添加快捷指令…」用），下载失败只影响这个可选功能
if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors "$REPO_RAW/focus.shortcut" -o "$APP/Contents/Resources/focus.shortcut"; then
  rm -f "$APP/Contents/Resources/focus.shortcut"
  msg "⚠️  勿扰快捷指令下载失败，只影响「共享时开启勿扰模式」；之后重新运行安装命令即可补上。" \
      "⚠️  Couldn't download the Do Not Disturb shortcut. Only \"Turn on Do Not Disturb while sharing\" is affected; run the install command again to add it." >&2
fi

# 1.1.x 及更早是两个程序（后台 sharewatch + 配置窗口 hideapps-config），现在合成一个，清掉旧文件。
rm -f "$APP/Contents/MacOS/hideapps-config" \
      "$APP_SUPPORT/sharewatch" "$APP_SUPPORT/共享时隐身" "$APP_SUPPORT/共享隐身"

# LSUIElement：平时只在菜单栏显示图标，打开配置窗口时才出现在 Dock。
# 文件名和 CFBundleDisplayName 都是「共享时隐身」，加上 LSHasLocalizedDisplayName，
# 英文系统的访达和菜单里就会显示 en.lproj 里的 ShareHide。
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
    <key>CFBundleShortVersionString</key><string>1.4</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSHasLocalizedDisplayName</key><true/>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>个别应用（如 Telegram）不响应普通隐藏，需要通过「系统事件」把它隐藏。</string>
</dict>
</plist>
PLIST_EOF
write_names() {
  mkdir -p "$APP/Contents/Resources/$1.lproj"
  printf '"CFBundleName" = "%s";\n"CFBundleDisplayName" = "%s";\n"NSAppleEventsUsageDescription" = "%s";\n' \
    "$2" "$2" "$3" > "$APP/Contents/Resources/$1.lproj/InfoPlist.strings"
}
write_names en "ShareHide" "A few apps (such as Telegram) ignore the normal hide request, so ShareHide hides them through System Events."
write_names zh-Hans "共享时隐身" "个别应用（如 Telegram）不响应普通隐藏，需要通过「系统事件」把它隐藏。"
write_names zh-Hant "共享时隐身" "个别应用（如 Telegram）不响应普通隐藏，需要通过「系统事件」把它隐藏。"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign -s - --force --deep "$APP" >/dev/null 2>&1 || true

msg "==> 生成配置文件（默认不隐藏任何应用，由你自己添加）" "==> Creating the settings file (no apps are hidden until you add them)"
if [ ! -f "$CONFIG" ]; then
  if [ "$ZH" = 1 ]; then
    cat > "$CONFIG" <<'CONF_EOF'
# 共享 / 录屏时要隐藏的应用，每行一个。
# 写 bundle id 或应用名；# 后面是备注。推荐用「共享时隐身」配置窗口管理。
# 例：com.tencent.xinWeChat   # 微信
CONF_EOF
  else
    cat > "$CONFIG" <<'CONF_EOF'
# Apps to hide while sharing or recording, one per line.
# Bundle id or app name; text after # is a note. Easiest to manage in the ShareHide window.
# Example: com.tinyspeck.slackmacgap   # Slack
CONF_EOF
  fi
fi

msg "==> 设置开机自启" "==> Setting it to start at login"
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

msg "==> 启动" "==> Starting"
STARTS_BEFORE=$(grep -c "启动（" "$LOG" 2>/dev/null || true)
for _ in 1 2 3; do
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break
  sleep 1
done
if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  msg "启动失败，请重新运行安装命令。日志：$LOG" "Failed to start. Please run the install command again. Log: $LOG" >&2
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
if [ "$ZH" = 1 ]; then
  echo "✅ 安装完成，已运行、开机自启，菜单栏右上角有个眼睛图标。"
  echo "   在刚弹出的「共享时隐身」窗口里，把要隐藏的应用加进去即可（即时生效）。"
  echo "   关掉窗口程序照常工作；以后点菜单栏图标「打开配置…」或打开 $APP 管理。"
  echo "   日志：$LOG"
  echo "   卸载：curl -fsSL $REPO_RAW/uninstall.sh | bash"
  echo "   提示：任何录屏 / 会议共享都会触发隐藏。"
else
  echo "✅ Installed. ShareHide is running and starts at login; look for the eye icon in the menu bar."
  echo "   In the ShareHide window that just opened, add the apps you want to hide (takes effect right away)."
  echo "   Closing the window keeps it running. Later, choose “Settings…” from the menu bar icon or open $APP."
  echo "   Log: $LOG"
  echo "   Uninstall: curl -fsSL $REPO_RAW/uninstall.sh | bash"
  echo "   Note: any screen recording or meeting share triggers hiding."
fi
