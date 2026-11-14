#!/bin/zsh
# 移除 “HP136wManualDuplex” 虚拟打印机；保留校准配置。
set -e
trap 'echo; echo "卸载失败（第 $LINENO 行）。"; read -r "?按 Enter 关闭窗口..."; exit 1' ZERR

USER_ID=$(id -u)
PLIST="$HOME/Library/LaunchAgents/com.hp136wduplex.watch.plist"

echo "=== 卸载 HP 136w 手动双面虚拟打印机 ==="
echo "会移除：LaunchAgent、CUPS 队列、backend、spool；保留校准配置。"
echo

launchctl bootout "gui/$USER_ID" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

lpadmin -x HP136wManualDuplex 2>/dev/null || true

sudo rm -f /usr/libexec/cups/backend/hpduplex
sudo rm -f /usr/local/bin/hpduplex
sudo rm -rf /Users/Shared/HP136wDuplex

echo
echo "已移除虚拟打印机。"
echo "校准配置仍在：$HOME/Library/Application Support/HP136wDuplex"
echo
read -r "?按 Enter 关闭窗口..."