# HP Laser MFP 136w 手动双面打印

把一台没有自动双面器的 HP Laser MFP 136w，在 macOS 上做成“手动双面”：

1. 打印奇数页（正面）
2. 提示翻纸、放回
3. 打印偶数页（背面，顺序/旋转按校准结果）

不修改系统驱动，不依赖 HP 厂商软件；本质是把同一个 PDF 分成两次 `lp` 任务。

## 日常使用：虚拟打印机

安装（需要管理员密码一次）：

```bash
scripts/install-virtual-printer.command
```

之后在**任何应用**的打印对话框里选择 **`HP136wManualDuplex`**：

```text
应用 → ⌘P → 选择 HP136wManualDuplex → 打印
        ↓
正面页从 136w 出来
        ↓
屏幕弹出“翻面后继续”对话框
        ↓
沿长边整体翻面、放回纸盒、点“继续”
        ↓
背面页打印完成
```

也可以命令行测试：

```bash
/usr/local/bin/hpduplex sample --pages 2 --out /tmp/hp136w-2p.pdf
lp -d HP136wManualDuplex /tmp/hp136w-2p.pdf
```

### 架构

```text
App → CUPS 队列 HP136wManualDuplex
        ↓ PDF 直通
backend (/usr/libexec/cups/backend/hpduplex, 以 _lp 运行)
        ↓ 只把 PDF 放进 spool，立即退出
/Users/Shared/HP136wDuplex/spool
        ↓
LaunchAgent (用户) → hpduplex watch
        ↓
正面 → 对话框 → 翻纸 → 背面 → 真机队列
```

- 虚拟队列的 job 会先显示完成，实际打印由用户 LaunchAgent 接管；
  打印后请等对话框/页面，不要连续发多个任务。
- 同一时间只处理一个任务；后面的任务在 spool 里排队。
- 日志：
  - `~/Library/Logs/HP136wDuplex/watch.log`
  - `/Users/Shared/HP136wDuplex/logs/backend.log`
- 失败/取消的任务会移到 spool 的 `failed/`。

卸载：

```bash
scripts/uninstall-virtual-printer.command
```

校准配置会保留；要彻底清除再删 `~/Library/Application Support/HP136wDuplex`。

## 直接打印 PDF（CLI）

```bash
swift build -c release

.build/release/hpduplex list
.build/release/hpduplex calibrate           # 重新校准（3–6 张纸）
.build/release/hpduplex print thesis.pdf    # 正面 → 翻纸 → 背面
.build/release/hpduplex print thesis.pdf --dry-run --open
```

## 项目结构

```text
Package.swift
Sources/
  DuplexCore/      # PDF 切页/重排/烤入旋转、队列发现、lp 封装
  hpduplex/        # CLI：print / preview / calibrate / config / watch
Tests/
  DuplexCoreTests/
docs/
  cli.md           # CLI 与校准说明
scripts/
  install-virtual-printer.command
  uninstall-virtual-printer.command
  hpduplex-backend
  HP136wManualDuplex.ppd
  calibrate.command
  rotation-test.command
```

## 已知限制

- 这是“两遍打印”，不是自动双面；中途必须有人翻纸
- 只支持 A4；虚拟队列里选 Letter 等不会改变真机纸张
- 多份会逐份处理，每份翻一次
- 混合纸张尺寸/方向暂不特殊处理
- 背面 1–3 mm 偏移可用 `--offset` 手动微调
- 只支持 macOS（PDFKit + CUPS `lp`）
- 虚拟打印机依赖用户登录后的 LaunchAgent；未登录时任务会留在 spool