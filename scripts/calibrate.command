#!/bin/zsh
# 双击运行：编译（如有需要）并启动 HP 136w 手动双面校准。
cd "$(dirname "$0")/.." || exit 1

if [ ! -x .build/release/hpduplex ]; then
  echo "正在编译 hpduplex..."
  swift build -c release || {
    echo
    echo "编译失败。"
    read -r "?按 Enter 关闭窗口..."
    exit 1
  }
fi

.build/release/hpduplex calibrate
status=$?

echo
echo "校准退出码：$status"
read -r "?按 Enter 关闭窗口..."
exit $status