#!/bin/zsh
# 快速验证：背面旋转 180° 是否真的被“烤”进打印内容。
cd "$(dirname "$0")/.." || exit 1

if [ ! -x .build/release/hpduplex ]; then
  echo "正在编译 hpduplex..."
  swift build -c release || {
    echo "编译失败。"
    read -r "?按 Enter 关闭窗口..."
    exit 1
  }
fi

.build/release/hpduplex sample --pages 2 --out /tmp/hp136w-rotation-test.pdf

echo
echo "=== 背面旋转验证（1 张纸）==="
echo "1. 准备一张 A4。"
echo "2. 按 Enter 后先打印 PAGE 1。"
echo "3. 把纸沿长边翻面（像翻书），放回纸盒。"
echo "4. 在提示处按 Enter，打印 PAGE 2（已烤入 180° 旋转）。"
echo "5. 检查 PAGE 2 是否正立。"
echo

read -r "?准备好后按 Enter 开始..."

.build/release/hpduplex print /tmp/hp136w-rotation-test.pdf --pages 1-2 --rotate 180 --yes
status=$?

echo
echo "退出码：$status"
echo "如果 PAGE 2 仍然倒置，请把结果告诉我；如果正立，说明修复生效。"
read -r "?按 Enter 关闭窗口..."
exit $status