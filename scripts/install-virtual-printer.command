#!/bin/zsh
# 安装 “HP136wManualDuplex” 虚拟打印机：
#   - CUPS backend（root）把 PDF 放进 spool
#   - 用户 LaunchAgent 运行 hpduplex watch，负责正面/翻纸/背面
set -e
trap 'echo; echo "安装失败（第 $LINENO 行）。"; read -r "?按 Enter 关闭窗口..."; exit 1' ZERR

cd "$(dirname "$0")/.." || exit 1

USER_NAME=$(id -un)
USER_ID=$(id -u)
SPOOL=/Users/Shared/HP136wDuplex/spool
LOGSPOOL=/Users/Shared/HP136wDuplex/logs
PLIST="$HOME/Library/LaunchAgents/com.hp136wduplex.watch.plist"
LOGDIR="$HOME/Library/Logs/HP136wDuplex"

echo "=== 安装 HP 136w 手动双面虚拟打印机 ==="
echo "需要管理员密码：CUPS backend 必须放在 /usr/libexec/cups/backend。"
echo

echo "[1/5] 编译..."
swift build -c release

echo "[2/5] 安装 CLI 和 CUPS backend..."
sudo install -d -m 755 /usr/local/bin
sudo install -m 755 -o root -g wheel .build/release/hpduplex /usr/local/bin/hpduplex
sudo install -m 700 -o root -g wheel scripts/hpduplex-backend /usr/libexec/cups/backend/hpduplex

echo "[3/5] 准备 spool..."
sudo mkdir -p "$SPOOL"
sudo chown "$USER_NAME:$(id -gn)" /Users/Shared/HP136wDuplex "$SPOOL"
sudo chgrp _lp "$SPOOL"
sudo chmod 755 /Users/Shared/HP136wDuplex
sudo chmod 2770 "$SPOOL"
sudo mkdir -p "$LOGSPOOL"
sudo chown "$USER_NAME:$(id -gn)" "$LOGSPOOL"
sudo chgrp _lp "$LOGSPOOL"
sudo chmod 2770 "$LOGSPOOL"
sudo touch "$LOGSPOOL/backend.log"
sudo chgrp _lp "$LOGSPOOL/backend.log"
sudo chmod 660 "$LOGSPOOL/backend.log"

echo "[4/5] 创建/更新 CUPS 队列..."
# 让 cupsd 重新扫描 backend
sudo killall -HUP cupsd 2>/dev/null || true
sleep 1

lpadmin -x HP136wManualDuplex 2>/dev/null || true
lpadmin -p HP136wManualDuplex -E \
  -v 'hpduplex:/' \
  -P scripts/HP136wManualDuplex.ppd \
  -D 'HP 136w Manual Duplex' \
  -o printer-is-shared=false
lpstat -p HP136wManualDuplex

echo "[5/5] 安装用户 watcher..."
mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hp136wduplex.watch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/hpduplex</string>
    <string>watch</string>
    <string>--spool</string>
    <string>$SPOOL</string>
    <string>--interval</string>
    <string>1</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$LOGDIR/watch.log</string>
  <key>StandardErrorPath</key>
  <string>$LOGDIR/watch.log</string>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$USER_ID" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$USER_ID" "$PLIST"
launchctl enable "gui/$USER_ID/com.hp136wduplex.watch"
launchctl kickstart -k "gui/$USER_ID/com.hp136wduplex.watch" 2>/dev/null || true

echo
echo "=== 完成 ==="
echo "虚拟队列：HP136wManualDuplex"
echo "spool：$SPOOL"
echo "日志：$LOGDIR/watch.log 和 $LOGSPOOL/backend.log"
echo
echo "在打印对话框里选择 “HP136wManualDuplex” 即可。"
echo "也可以命令行测试："
echo "  /usr/local/bin/hpduplex sample --pages 2 --out /tmp/hp136w-2p.pdf"
echo "  lp -d HP136wManualDuplex /tmp/hp136w-2p.pdf"
echo
echo "注意：首次打印会先出正面，随后弹出“翻面后继续”的对话框。"
echo
read -r "?按 Enter 关闭窗口..."