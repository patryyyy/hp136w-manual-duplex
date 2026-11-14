import Foundation
import PDFKit
import DuplexCore

public enum CLI {
    public static func run(_ arguments: [String]) throws {
        let parsed = try ParsedArgs.parse(arguments)

        if parsed.flag("help") || parsed.command == nil {
            printHelp()
            return
        }

        switch parsed.command {
        case "list":
            try commandList(parsed)
        case "sample":
            try commandSample(parsed)
        case "preview":
            try commandPreview(parsed)
        case "print":
            try commandPrint(parsed)
        case "calibrate":
            try commandCalibrate(parsed)
        case "config":
            try commandConfig(parsed)
        case "status":
            try commandStatus(parsed)
        case "watch":
            try commandWatch(parsed)
        case let command?:
            throw CLIError.unknownCommand(command)
        case nil:
            printHelp()
        }
    }

    // MARK: - 命令

    private static func commandList(_ parsed: ParsedArgs) throws {
        _ = parsed
        let queues = Printer.queues()
        let config = ConfigStore.load()

        guard !queues.isEmpty else {
            print("没有找到任何 CUPS 队列。")
            return
        }

        for queue in queues {
            let marker = queue.is136w ? "*" : " "
            print("\(marker) \(queue.name)")
            print("    型号: \(queue.displayModel)")
            print("    URI : \(queue.uri)")
            print("    PPD : \(queue.ppdPath)\(queue.hasPPD ? "" : "（不存在）")")
            if config.queue == queue.name {
                print("    配置: 当前保存的队列")
            }
        }

        print("\n* = 自动识别为 HP Laser MFP 136 系列")
        print("配置文件: \(ConfigStore.fileURL.path)")
    }

    private static func commandSample(_ parsed: ParsedArgs) throws {
        let count = Int(parsed.value("pages") ?? "4") ?? 4
        guard count >= 1, count <= 100 else {
            throw CLIError.invalidValue("--pages 需要在 1...100 之间")
        }

        let path = parsed.value("out") ?? "hp136w-sample.pdf"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let document = parsed.flag("calibration")
            ? PDFBuilder.makeCalibrationPDF()
            : PDFBuilder.makeSamplePDF(pageCount: count)
        try PDFBuilder.write(document, to: url)
        print("已生成 \(url.path)（\(document.pageCount) 页，A4）")
    }

    private static func commandPreview(_ parsed: ParsedArgs) throws {
        let context = try prepareJob(parsed, needQueue: false)
        _ = try writePreview(context, parsed: parsed)
    }

    private static func commandPrint(_ parsed: ParsedArgs) throws {
        let context = try prepareJob(parsed, needQueue: !parsed.flag("dry-run"))

        if parsed.flag("dry-run") {
            _ = try writePreview(context, parsed: parsed)
            return
        }

        guard let queue = context.queue else {
            throw PrinterError.queueNotFound("未指定队列")
        }

        printSummary(context)

        if !context.config.calibrated {
            print("\n⚠️ 还没有校准。当前用默认参数：长边 / 背面逆序 / 旋转 0°。")
            print("   建议先运行：hpduplex calibrate")
            if !parsed.flag("yes") {
                guard Interaction.isTTY else { throw CLIError.notInteractive }
                if !Interaction.confirm("仍要用默认参数继续？", defaultYes: false) {
                    return
                }
            }
        }

        if context.plan.needsBackPass && context.copies > 1 {
            print("\n注意：多份会逐份处理，每份都要翻一次纸。")
        }

        if Printer.isStopped(queue: queue.name) {
            print("\n⚠️ 队列当前不是可打印状态：")
            print(Printer.status(queue: queue.name))
            if !parsed.flag("yes") {
                guard Interaction.isTTY else { throw CLIError.notInteractive }
                if !Interaction.confirm("仍要尝试打印？", defaultYes: false) {
                    return
                }
            }
        }

        if !parsed.flag("yes") {
            guard Interaction.isTTY else { throw CLIError.notInteractive }
            if !Interaction.confirm("开始打印正面？") {
                return
            }
        }

        if context.plan.needsBackPass && !parsed.flag("gui") {
            let auto = Int(parsed.value("auto-continue") ?? "0") ?? 0
            if auto <= 0, !Interaction.isTTY {
                throw CLIError.notInteractive
            }
        }

        let workDirectory = try makeWorkDirectory(prefix: "job")
        let frontURL = workDirectory.appendingPathComponent("front.pdf")
        var backURL: URL?

        try PDFBuilder.write(context.front, to: frontURL)
        if context.plan.needsBackPass {
            let url = workDirectory.appendingPathComponent("back.pdf")
            try PDFBuilder.write(context.back, to: url)
            backURL = url
        }

        var allCompleted = false
        defer {
            if parsed.flag("keep") {
                print("临时文件保留在：\(workDirectory.path)")
            } else if allCompleted {
                try? FileManager.default.removeItem(at: workDirectory)
            } else {
                print("打印未完成，临时文件保留：\(workDirectory.path)")
            }
        }

        for copy in 1...context.copies {
            if context.copies > 1 {
                print("\n=== 第 \(copy)/\(context.copies) 份 ===")
            }
            let completed = try printOneCopy(
                context,
                queue: queue,
                frontURL: frontURL,
                backURL: backURL,
                parsed: parsed
            )
            if !completed {
                print("\n已停止，未打印后续份数。")
                throw CLIError.canceled
            }
        }

        allCompleted = true
        print("\n完成。")
    }

    private static func commandCalibrate(_ parsed: ParsedArgs) throws {
        var config = ConfigStore.load()
        try applyOverrides(&config, parsed)

        let queue = try resolveQueue(
            preferred: parsed.value("queue") ?? config.queue,
            strict: parsed.value("queue") != nil,
            interactive: true
        )

        let result = try Calibration.run(
            queue: queue,
            current: config,
            force: parsed.flag("force")
        )

        try ConfigStore.save(result)
        print("\n校准配置已保存：\(ConfigStore.fileURL.path)")
        printConfig(result)
    }

    private static func commandConfig(_ parsed: ParsedArgs) throws {
        var config = ConfigStore.load()

        if parsed.flag("reset") {
            config = .default
            try ConfigStore.save(config)
            print("已重置为默认配置。")
        }

        if let assignment = parsed.value("set") {
            try applyAssignment(&config, assignment)
            try ConfigStore.save(config)
        }

        printConfig(config)
    }

    private static func commandStatus(_ parsed: ParsedArgs) throws {
        let config = ConfigStore.load()
        let queue = try resolveQueue(
            preferred: parsed.value("queue") ?? config.queue,
            strict: parsed.value("queue") != nil,
            interactive: false
        )

        print("队列: \(queue.name)")
        print("型号: \(queue.displayModel)")
        print("状态: \(Printer.status(queue: queue.name))")

        let jobs = Shell.run("/usr/bin/lpstat", ["-o", queue.name])
        let active = jobs.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        print("\n活动任务:")
        print(active.isEmpty ? "  （无）" : active)

        print("\n校准: \(config.calibrated ? "是" : "否")")
        if config.calibrated {
            printConfig(config)
        }
    }

    // MARK: - 虚拟打印机 watcher

    private static func commandWatch(_ parsed: ParsedArgs) throws {
        let spoolPath = parsed.value("spool") ?? "/Users/Shared/HP136wDuplex/spool"
        let interval = max(0.2, Double(parsed.value("interval") ?? "1") ?? 1)
        let once = parsed.flag("once")

        let fileManager = FileManager.default
        let spool = URL(fileURLWithPath: spoolPath, isDirectory: true)
        try fileManager.createDirectory(at: spool, withIntermediateDirectories: true)

        let failedDirectory = spool.appendingPathComponent("failed", isDirectory: true)
        try? fileManager.createDirectory(at: failedDirectory, withIntermediateDirectories: true)

        print("[watch] spool: \(spool.path)")
        print("[watch] config: \(ConfigStore.fileURL.path)")

        if !ConfigStore.load().calibrated {
            print("[watch] 警告：配置未校准，暂不处理打印任务。")
        }

        while true {
            let config = ConfigStore.load()
            let files = (try? fileManager.contentsOfDirectory(
                at: spool,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            let pending = files
                .filter { $0.pathExtension.lowercased() == "pdf" && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { left, right in
                    let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return leftDate < rightDate
                }

            for file in pending {
                guard config.calibrated else { break }

                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if Date().timeIntervalSince(modified) > 3600 {
                    print("[watch] 跳过超过 1 小时的任务：\(file.lastPathComponent)")
                    let destination = failedDirectory
                        .appendingPathComponent(file.lastPathComponent + ".stale")
                    try? fileManager.moveItem(at: file, to: destination)
                    continue
                }

                let copies = copiesFromSpoolName(file.lastPathComponent)
                print("[watch] 处理 \(file.lastPathComponent)（\(copies) 份）")
                let status = runPrintChild(file: file, copies: copies)

                if status == 0 {
                    try? fileManager.removeItem(at: file)
                    print("[watch] 完成")
                } else {
                    print("[watch] 打印失败/取消，移到 failed")
                    let destination = failedDirectory
                        .appendingPathComponent(file.lastPathComponent + ".failed")
                    try? fileManager.removeItem(at: destination)
                    try? fileManager.moveItem(at: file, to: destination)
                }
            }

            if once { return }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private static func runPrintChild(file: URL, copies: Int) -> Int32 {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "print", file.path,
            "--yes", "--gui",
            "--copies", String(copies),
            "--config", ConfigStore.fileURL.path
        ]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            print("[watch] 启动打印子进程失败：\(error.localizedDescription)")
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func copiesFromSpoolName(_ name: String) -> Int {
        let pattern = "-c([0-9]+)-[0-9]+-[0-9]+\\.pdf$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, options: [], range: NSRange(name.startIndex..<name.endIndex, in: name)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: name),
              let value = Int(name[range]), value >= 1 else {
            return 1
        }
        return min(value, 50)
    }

    // MARK: - 打印

    private struct JobContext {
        let source: PDFDocument
        let sourceURL: URL
        let selected: [Int]
        let plan: PagePlan
        let front: PDFDocument
        let back: PDFDocument
        let config: DuplexConfig
        let queue: PrintQueue?
        let copies: Int
    }

    private static func prepareJob(_ parsed: ParsedArgs, needQueue: Bool) throws -> JobContext {
        guard let path = parsed.positional.first else {
            throw CLIError.missingPDF
        }

        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PDFBuilderError.cannotOpen(sourceURL.path)
        }

        let source = try PDFBuilder.load(sourceURL)
        let configURL = parsed.value("config").map { URL(fileURLWithPath: $0) }
        var config = ConfigStore.load(from: configURL)
        try applyOverrides(&config, parsed)

        if let offset = try parseOffset(parsed.value("offset")) {
            config.offsetX = offset.x
            config.offsetY = offset.y
        }

        let selected = try PageRange.parse(parsed.value("pages"), pageCount: source.pageCount)
        let scale = 72.0 / 25.4
        let offset = CGPoint(x: config.offsetX * scale, y: config.offsetY * scale)

        let (front, back, plan) = PDFBuilder.build(
            source: source,
            selected: selected,
            order: config.backOrder,
            blankSide: config.blankSide,
            rotation: config.normalizedRotation,
            offset: offset
        )

        let queue: PrintQueue?
        if needQueue {
            queue = try resolveQueue(
                preferred: parsed.value("queue") ?? config.queue,
                strict: parsed.value("queue") != nil,
                interactive: !parsed.flag("yes")
            )
        } else {
            queue = nil
        }

        let copies = try parseCopies(parsed.value("copies"))

        return JobContext(
            source: source,
            sourceURL: sourceURL,
            selected: selected,
            plan: plan,
            front: front,
            back: back,
            config: config,
            queue: queue,
            copies: copies
        )
    }

    @discardableResult
    private static func printOneCopy(
        _ context: JobContext,
        queue: PrintQueue,
        frontURL: URL,
        backURL: URL?,
        parsed: ParsedArgs
    ) throws -> Bool {
        let frontJob = try Printer.printFile(
            frontURL.path,
            queue: queue.name,
            media: context.config.media,
            jobName: "hpduplex front \(context.sourceURL.lastPathComponent)"
        )
        print("正面任务 \(frontJob)，等待打印完成...")
        try Printer.waitForJob(
            id: frontJob,
            queue: queue.name,
            timeout: parseTimeout(parsed),
            poll: 0.5
        )
        print("正面完成。")

        guard context.plan.needsBackPass, let backURL else {
            print("只有一页，无需背面。")
            return true
        }

        let auto = Int(parsed.value("auto-continue") ?? "0") ?? 0
        if auto > 0 {
            print("\n\(auto) 秒后自动继续打印背面。请现在翻纸。")
            Thread.sleep(forTimeInterval: TimeInterval(auto))
        } else if parsed.flag("gui") {
            let message = guiFlipMessage(context.config)
            if !Interaction.guiConfirm(message) {
                print("\n已在对话框中取消背面。")
                return false
            }
        } else {
            printFlipInstructions(context.config)
            print("\n翻好并放回纸盒后按 Enter 继续；输入 c 取消。", terminator: "")
            guard let line = readLine() else { throw CLIError.notInteractive }
            let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["c", "cancel", "q", "quit"].contains(answer) {
                print("\n已取消背面。正面已经打印，纸盒里是半成品。")
                return false
            }
        }

        let backJob = try Printer.printFile(
            backURL.path,
            queue: queue.name,
            media: context.config.media,
            jobName: "hpduplex back \(context.sourceURL.lastPathComponent)"
        )
        print("背面任务 \(backJob)，等待打印完成...")
        try Printer.waitForJob(
            id: backJob,
            queue: queue.name,
            timeout: parseTimeout(parsed),
            poll: 0.5
        )
        print("背面完成。")
        return true
    }

    private static func guiFlipMessage(_ config: DuplexConfig) -> String {
        let edge: String
        switch config.flip {
        case .long:
            edge = "沿长边整体翻面（像翻书）"
        case .short:
            edge = "沿短边整体翻面（像翻日历）"
        }
        return "正面已打印。请\(edge)，让空白面朝上，把整叠放回纸盒，然后点“继续”。"
    }

    private static func printFlipInstructions(_ config: DuplexConfig) {
        print("\n=== 现在翻面 ===")
        print("1. 取出整叠纸，不要打散。")
        switch config.flip {
        case .long:
            print("2. 沿长边整体翻面（像合上书再翻到背面）：左右翻，保持纸的上下边不变。")
        case .short:
            print("2. 沿短边整体翻面（像翻日历）：上下翻，纸的上下边对调。")
        }
        print("3. 把整叠放回纸盒（不要一张张翻）。")
        if config.normalizedRotation != 0 {
            print("   （已配置背面旋转 \(config.normalizedRotation)°，不需要你手动转纸。）")
        }
    }

    private static func writePreview(
        _ context: JobContext,
        parsed: ParsedArgs
    ) throws -> (front: URL, back: URL?) {
        let directory = try makeWorkDirectory(prefix: "preview")
        let frontURL = directory.appendingPathComponent("front.pdf")
        try PDFBuilder.write(context.front, to: frontURL)

        var backURL: URL?
        if context.plan.needsBackPass {
            let url = directory.appendingPathComponent("back.pdf")
            try PDFBuilder.write(context.back, to: url)
            backURL = url
        }

        printSummary(context)
        print("\n（dry-run，不发送到打印机）")
        print("正面 PDF: \(frontURL.path)")
        if let backURL {
            print("背面 PDF: \(backURL.path)")
        } else {
            print("背面 PDF: （只有一页，不需要）")
        }

        if parsed.flag("open") {
            _ = Shell.run("/usr/bin/open", [frontURL.path])
            if let backURL {
                _ = Shell.run("/usr/bin/open", [backURL.path])
            }
        }

        return (frontURL, backURL)
    }

    private static func printSummary(_ context: JobContext) {
        let selectedPages = context.plan.selected.map { String($0 + 1) }
        let frontPages = context.plan.frontIndices.map { String($0 + 1) }
        let backPages = context.plan.backSequence(
            order: context.config.backOrder,
            blankSide: context.config.blankSide
        ).map(PagePlan.label)

        print("队列   : \(context.queue?.name ?? "（preview，无需队列）")")
        print("文档   : \(context.sourceURL.lastPathComponent)（\(context.source.pageCount) 页）")
        print("打印   : 选中 \(selectedPages.count) 页 → \(context.plan.sheetCount) 张纸 × \(context.copies) 份")
        print("选中页 : \(abbreviate(selectedPages))")
        print("正面   : \(abbreviate(frontPages))")
        print("背面   : \(context.plan.needsBackPass ? abbreviate(backPages) : "（无）")")
        print("翻面   : \(context.config.flip.displayName) / 背面\(context.config.backOrder.displayName) / 旋转 \(context.config.normalizedRotation)° / 空白\(context.config.blankSide.displayName)")
        if context.config.offsetX != 0 || context.config.offsetY != 0 {
            print("背面偏移: \(context.config.offsetX), \(context.config.offsetY) mm")
        }
    }

    // MARK: - 参数/队列

    private static func resolveQueue(
        preferred: String?,
        strict: Bool,
        interactive: Bool
    ) throws -> PrintQueue {
        if let preferred, !preferred.isEmpty {
            if let queue = Printer.queue(named: preferred) {
                return queue
            }
            if strict {
                throw PrinterError.queueNotFound(preferred)
            }
            print("⚠️ 保存的队列 \(preferred) 不存在，重新查找 136w。")
        }

        let candidates = Printer.discover136w()
        if candidates.count == 1 {
            return candidates[0]
        }

        let all = Printer.queues()
        if candidates.isEmpty {
            print("没有自动识别到 HP Laser MFP 136 系列队列。现有队列：")
            for queue in all {
                print("  - \(queue.name)  [\(queue.displayModel)]")
            }
            if interactive, !all.isEmpty {
                let index = try Interaction.choice(
                    "选择要使用的队列：",
                    options: all.map { "\($0.name)  [\($0.displayModel)]" }
                )
                return all[index - 1]
            }
            throw PrinterError.queueNotFound("HP Laser MFP 136w（请用 --queue 指定）")
        }

        if interactive {
            let index = try Interaction.choice(
                "发现多个候选队列，选择：",
                options: candidates.map { "\($0.name)  [\($0.displayModel)]" }
            )
            return candidates[index - 1]
        }

        throw CLIError.invalidValue("发现多个 136w 队列，请用 --queue 指定")
    }

    private static func applyOverrides(_ config: inout DuplexConfig, _ parsed: ParsedArgs) throws {
        if let value = parsed.value("flip") {
            guard let flip = FlipEdge(rawValue: value.lowercased()) else {
                throw CLIError.invalidValue("--flip 只能是 long 或 short")
            }
            config.flip = flip
        }

        if let value = parsed.value("rotate") ?? parsed.value("rotation") {
            guard let rotation = Int(value), rotation == 0 || rotation == 180 else {
                throw CLIError.invalidValue("--rotate 只能是 0 或 180")
            }
            config.rotation = rotation
        }

        if let value = parsed.value("back-order") {
            guard let order = BackOrder(rawValue: value.lowercased()) else {
                throw CLIError.invalidValue("--back-order 只能是 asc 或 desc")
            }
            config.backOrder = order
        }

        if let value = parsed.value("blank") {
            guard let side = BlankSide(rawValue: value.lowercased()) else {
                throw CLIError.invalidValue("--blank 只能是 leading 或 trailing")
            }
            config.blankSide = side
        }

        if let value = parsed.value("media"), !value.isEmpty {
            config.media = value
        }

        if let value = parsed.value("queue"), !value.isEmpty {
            config.queue = value
        }
    }

    private static func applyAssignment(_ config: inout DuplexConfig, _ assignment: String) throws {
        let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw CLIError.invalidValue("--set 需要 key=value")
        }
        let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let value = parts[1].trimmingCharacters(in: .whitespaces)

        switch key {
        case "flip":
            guard let flip = FlipEdge(rawValue: value.lowercased()) else {
                throw CLIError.invalidValue("flip 只能是 long 或 short")
            }
            config.flip = flip
        case "rotate", "rotation":
            guard let rotation = Int(value), rotation == 0 || rotation == 180 else {
                throw CLIError.invalidValue("rotation 只能是 0 或 180")
            }
            config.rotation = rotation
        case "back-order", "backorder":
            guard let order = BackOrder(rawValue: value.lowercased()) else {
                throw CLIError.invalidValue("back-order 只能是 asc 或 desc")
            }
            config.backOrder = order
        case "blank":
            guard let side = BlankSide(rawValue: value.lowercased()) else {
                throw CLIError.invalidValue("blank 只能是 leading 或 trailing")
            }
            config.blankSide = side
        case "queue":
            config.queue = value
        case "media":
            config.media = value
        case "offset":
            let offset = try parseOffset(value)
            config.offsetX = offset?.x ?? 0
            config.offsetY = offset?.y ?? 0
        case "calibrated":
            config.calibrated = ["true", "1", "yes"].contains(value.lowercased())
        default:
            throw CLIError.invalidValue("不认识的配置键：\(key)")
        }
    }

    private static func parseOffset(_ text: String?) throws -> (x: Double, y: Double)? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              abs(x) <= 50,
              abs(y) <= 50 else {
            throw CLIError.invalidValue("--offset 需要 X,Y（mm，绝对值不超过 50）")
        }
        return (x, y)
    }

    private static func parseCopies(_ value: String?) throws -> Int {
        guard let value, !value.isEmpty else { return 1 }
        guard let copies = Int(value), copies >= 1, copies <= 50 else {
            throw CLIError.invalidValue("--copies 需要在 1...50 之间")
        }
        return copies
    }

    private static func parseTimeout(_ parsed: ParsedArgs) -> TimeInterval {
        if let value = parsed.value("timeout"), let timeout = TimeInterval(value), timeout > 0 {
            return timeout
        }
        return 300
    }

    private static func makeWorkDirectory(prefix: String) throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HP136wDuplex", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let directory = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func abbreviate(_ values: [String], limit: Int = 14) -> String {
        guard values.count > limit else { return values.joined(separator: ",") }
        let head = values.prefix(6).joined(separator: ",")
        let tail = values.suffix(3).joined(separator: ",")
        return "\(head),…,\(tail)（共 \(values.count) 页）"
    }

    private static func printConfig(_ config: DuplexConfig) {
        let formatter = ISO8601DateFormatter()
        print("\n配置: \(ConfigStore.fileURL.path)")
        print("  队列     : \(config.queue ?? "（自动）")")
        print("  机型     : \(config.printerModel ?? "（未知）")")
        print("  翻面     : \(config.flip.displayName)")
        print("  背面顺序 : \(config.backOrder.displayName)")
        print("  背面旋转 : \(config.normalizedRotation)°")
        print("  空白位置 : \(config.blankSide.displayName)")
        print("  背面偏移 : \(config.offsetX), \(config.offsetY) mm")
        print("  纸张     : \(config.media)")
        print("  已校准   : \(config.calibrated ? "是" : "否")")
        if let date = config.calibratedAt {
            print("  校准时间 : \(formatter.string(from: date))")
        }
    }

    private static func printHelp() {
        print("""
        hpduplex — HP Laser MFP 136w 手动双面打印

        用法:
          hpduplex list
          hpduplex sample [--pages 4] [--out file.pdf]
          hpduplex preview <file.pdf> [选项] [--open]
          hpduplex print <file.pdf> [选项]
          hpduplex calibrate [--queue NAME] [--force]
          hpduplex config [--set key=value] [--reset]
          hpduplex status [--queue NAME]
          hpduplex watch [--spool DIR] [--interval 1] [--once]

        打印选项:
          --queue NAME        指定 CUPS 队列（默认自动找 136w）
          --pages 1-5,8       只打印这些页；按选中顺序配对正反面
          --copies N          份数（逐份处理，每份翻一次纸）
          --flip long|short   翻面方式（默认读校准配置）
          --rotate 0|180      背面旋转（默认读校准配置）
          --back-order asc|desc  背面顺序（默认读校准配置）
          --blank leading|trailing  奇数页空白补在背面序列的开头/结尾
          --media A4|auto     纸张（默认 A4；auto 不传 media）
          --offset X,Y        背面偏移 mm（高级；PDF 坐标 x 右 y 上）
          --dry-run           只生成 front.pdf/back.pdf，不打印
          --yes               跳过“开始打印？”确认（翻纸仍需按 Enter）
          --auto-continue N   正面完成后 N 秒自动继续（脚本用）
          --timeout N         每个打印任务等待秒数（默认 300）
          --config PATH       读取指定校准配置（虚拟打印机后端用）
          --gui               用 macOS 对话框提示翻纸（虚拟打印机后端用）
          --keep              保留临时 PDF

        虚拟打印机:
          watch 会扫描 spool 目录里的 PDF，逐个调用 print --gui；
          由 LaunchAgent 启动，不需要终端。

        示例:
          hpduplex calibrate
          hpduplex print thesis.pdf --pages 1-20
          hpduplex print thesis.pdf --dry-run --open
          hpduplex print thesis.pdf --pages 1-100 --yes --auto-continue 20

        说明:
          打印机必须已经在“系统设置 → 打印机与扫描仪”里添加。
          本工具不修改系统驱动，只是把同一个 PDF 分成正面/背面两次提交。
        """)
    }
}