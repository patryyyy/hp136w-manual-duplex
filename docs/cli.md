# hpduplex CLI 使用与校准

## 编译

```bash
swift build -c release
```

二进制：`.build/release/hpduplex`。

调试版：`swift build && .build/debug/hpduplex`。

## 命令

### list

```bash
hpduplex list
```

列出 CUPS 队列，`*` 标记自动识别到的 HP Laser MFP 136 系列。

### sample

```bash
hpduplex sample --pages 4 --out hp136w-sample.pdf
hpduplex sample --calibration --out cal.pdf
```

生成测试 PDF（A4，每页有页码、TOP 箭头、十字线）。`--calibration` 生成校准用的 FRONT/BACK 页。

### preview / --dry-run

```bash
hpduplex preview thesis.pdf --open
hpduplex print thesis.pdf --dry-run
```

只生成 `front.pdf` / `back.pdf`，显示页序，不发送到打印机。`--open` 用预览打开。

### print

```bash
hpduplex print thesis.pdf
hpduplex print thesis.pdf --pages 1-20
hpduplex print thesis.pdf --copies 2
```

流程：

1. 显示页序摘要（正面页、背面页、翻面方式）
2. 确认后打印正面，等待 job 完成
3. 显示翻纸说明；按 Enter 后打印背面
4. 等待完成，清理临时文件

`--yes` 只跳过“开始打印正面？”的确认；**翻纸仍然要按 Enter**。脚本里用：

```bash
hpduplex print thesis.pdf --yes --auto-continue 20
```

（正面完成后等 20 秒，给用户翻纸，然后自动印背面。）

### calibrate

```bash
hpduplex calibrate
hpduplex calibrate --force
```

交互式校准，会打印 3–6 张 A4。建议准备 5 张以上。

步骤：

1. **单张翻面测试**
   - 打印 `FRONT 1`
   - 问你现在朝上的是正面还是空白
   - 按提示翻面（长边/短边）后打印 `BACK 2`
   - 问 `②` 是否正立、是否在 `①` 背面
   - 长边失败会改试短边
2. **页序测试（2 张）**
   - 打印 `FRONT 1`、`FRONT 3`
   - 只翻看最上面一张，确认是 1 还是 3
   - 按提示翻整叠，打印背面 `4,2`（或 `2,4`）
   - 检查成品是否 `1/2、3/4` 且背面正立
3. 保存配置

校准结果：

```json
{
  "queue": "<用 hpduplex list 看到的真实队列名>",
  "flip": "long",
  "rotation": 0,
  "backOrder": "desc",
  "blankSide": "leading",
  "media": "A4",
  "calibrated": true
}
```

## 配置

```bash
hpduplex config
hpduplex config --set flip=short
hpduplex config --set rotate=180
hpduplex config --set back-order=asc
hpduplex config --set offset=1.5,-0.8
hpduplex config --reset
```

文件：`~/Library/Application Support/HP136wDuplex/config.json`。

`offset` 单位 mm，PDF 坐标（x 向右、y 向上）；只影响背面。

> 背面旋转（0/180）是“烤”进 PDF 页面内容的，不是只写 PDF 的 `/Rotate` 标记。
> 原因：AirPrint/CUPS 的打印路径会忽略 `/Rotate`，只写标记的话实际打印不会转。

## 打印选项

| 选项 | 说明 |
|---|---|
| `--queue NAME` | 指定 CUPS 队列；默认自动找 136w |
| `--pages 1-5,8` | 只打印这些页；按选中顺序配对正反面 |
| `--copies N` | 份数，逐份处理，每份翻一次 |
| `--flip long\|short` | 翻面方式（默认读配置） |
| `--rotate 0\|180` | 背面旋转（默认读配置） |
| `--back-order asc\|desc` | 背面顺序（默认读配置） |
| `--blank leading\|trailing` | 奇数页空白补在背面序列开头/结尾 |
| `--media A4\|auto` | 纸张；auto 表示不传 media |
| `--offset X,Y` | 背面偏移 mm（高级） |
| `--dry-run` | 只生成 PDF，不打印 |
| `--yes` | 跳过开始确认（仍需翻纸 Enter） |
| `--auto-continue N` | 正面完成后 N 秒自动继续 |
| `--timeout N` | 每个 job 等待秒数（默认 300） |
| `--keep` | 保留临时 PDF |
| `--config PATH` | 读取指定校准配置（虚拟打印机后端用） |
| `--gui` | 用 macOS 对话框提示翻纸（无终端场景） |

## CUPS 虚拟打印机

安装：

```bash
scripts/install-virtual-printer.command
```

安装后打印对话框里会出现 **`HP136wManualDuplex`**。它收到 PDF 后：

1. CUPS backend（以 `_lp` 运行）把 PDF 放进 `/Users/Shared/HP136wDuplex/spool`
2. 用户 LaunchAgent 运行 `hpduplex watch`
3. `watch` 调 `hpduplex print --gui`：正面 → 对话框 → 翻纸 → 背面

注意：虚拟队列的 CUPS job 会先显示完成，实际打印由 LaunchAgent 接管；
打印后等对话框/页面，不要连续发多个任务。

日志：

- `~/Library/Logs/HP136wDuplex/watch.log`
- `/Users/Shared/HP136wDuplex/logs/backend.log`

失败/取消的任务在 spool 的 `failed/`。

手动运行 watcher（调试）：

```bash
/usr/local/bin/hpduplex watch --spool /Users/Shared/HP136wDuplex/spool --once
```

卸载：

```bash
scripts/uninstall-virtual-printer.command
```

## 排查

### 没有找到队列

```bash
lpstat -v
lpstat -p
```

打印机要先在“系统设置 → 打印机与扫描仪”里添加。仍不行就：

```bash
hpduplex list
hpduplex print file.pdf --queue <队列名>
```

### 页序不对

先 `--dry-run` 看 `front.pdf` / `back.pdf` 的页序，再试：

```bash
hpduplex print file.pdf --back-order asc
hpduplex print file.pdf --back-order desc
```

### 背面倒置

```bash
hpduplex print file.pdf --rotate 180
```

### 背面偏移

先用校准页（或任意两页）印一张双面，对着光量偏移，然后：

```bash
hpduplex print file.pdf --offset 1.5,-0.5
```

### 半成品/取消

正面已经打印后取消，纸盒里是半成品；工具会保留临时 PDF 方便重印背面：

```bash
hpduplex print file.pdf --keep
```

### 任务一直不结束

```bash
hpduplex status
lpstat -o
lpstat -p
```

可能是打印机离线、缺纸、队列被暂停。`--timeout` 只控制工具等待时间，不会取消打印机任务；需要时用 `cancel <job-id>`。

## 卸载

```bash
rm -rf ~/Library/Application\ Support/HP136wDuplex
rm -rf ~/Library/Caches/HP136wDuplex
```

删除二进制即可。