#!/bin/bash
# 共享时隐身 —— 卸载
set -uo pipefail

APP_SUPPORT="$HOME/Library/Application Support/ShareHideApps"
PLIST="$HOME/Library/LaunchAgents/com.sharehideapps.agent.plist"
LOG="$HOME/Library/Logs/ShareHideApps.log"
LABEL="com.sharehideapps.agent"
CONFIG_APP="$HOME/Applications/共享时隐身.app"

case "$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | tr -d ' ",')" in
  zh*) ZH=1 ;;
  *) ZH=0 ;;
esac
msg() { if [ "$ZH" = 1 ]; then echo "$1"; else echo "$2"; fi; }

msg "==> 卸载「共享时隐身」" "==> Uninstalling ShareHide"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# 双击打开的那份不归 launchd 管，单独结束
pkill -x ShareHideApps 2>/dev/null || true
pkill -x hideapps-config 2>/dev/null || true
rm -f "$PLIST"
# sharewatch 和两个包装脚本是 1.1.x 及更早的旧文件，「共享隐身」是改名前的名字
rm -f "$APP_SUPPORT/sharewatch" "$APP_SUPPORT/共享时隐身" "$APP_SUPPORT/共享隐身" "$APP_SUPPORT/apps.conf"
rm -rf "$CONFIG_APP"
# 「共享时隐藏桌面图标」等设置
defaults delete com.sharehideapps.app 2>/dev/null || true
rmdir "$APP_SUPPORT" 2>/dev/null || true

msg "✅ 已卸载。日志保留在：${LOG}（如不需要可手动删除）" "✅ Uninstalled. The log is kept at ${LOG} (delete it if you don't need it)."
