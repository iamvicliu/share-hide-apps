#!/bin/bash
# 共享时隐身 —— 卸载
set -uo pipefail

APP_SUPPORT="$HOME/Library/Application Support/ShareHideApps"
PLIST="$HOME/Library/LaunchAgents/com.sharehideapps.agent.plist"
LOG="$HOME/Library/Logs/ShareHideApps.log"
LABEL="com.sharehideapps.agent"
CONFIG_APP="$HOME/Applications/共享时隐身.app"

echo "==> 卸载「共享时隐身」"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
# 「共享隐身」是改名前的旧包装脚本
rm -f "$APP_SUPPORT/sharewatch" "$APP_SUPPORT/共享时隐身" "$APP_SUPPORT/共享隐身" "$APP_SUPPORT/apps.conf"
rm -rf "$CONFIG_APP"
rmdir "$APP_SUPPORT" 2>/dev/null || true

echo "✅ 已卸载。日志保留在：${LOG}（如不需要可手动删除）"
