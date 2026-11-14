import Foundation
import PDFKit
import DuplexCore

public enum Calibration {
    public static func run(
        queue: PrintQueue,
        current: DuplexConfig,
        force: Bool
    ) throws -> DuplexConfig {
        guard Interaction.isTTY else { throw CLIError.notInteractive }

        print("""
        === HP Laser MFP 136w 手动双面校准 ===
        队列: \(queue.name)
        型号: \(queue.displayModel)

        会打印 3–6 张 A4。请准备几张白纸。
        每一步都要你实际翻纸；工具只负责出纸和记录结果。
        """)

        if current.calibrated && !force {
            if !Interaction.confirm("这台打印机已经校准过，重新校准？", defaultYes: false) {
                return current
            }
        }

        try Interaction.pause("\n准备好后按 Enter 开始。")

        let document = PDFBuilder.makeCalibrationPDF()
        let media = current.media

        // 1) 单张：翻面方向 + 背面旋转
        print("\n[1/3] 单张翻面测试")
        print("先试长边（像翻书）。")

        var flip: FlipEdge = .long
        var rotation: Int
        if let result = try determineFlip(document: document, queue: queue, media: media, edge: .long) {
            rotation = result
            print("长边测试通过：背面旋转 \(rotation)°。")
        } else {
            print("\n长边没得到正确结果，改试短边（像翻日历）。")
            guard let result = try determineFlip(document: document, queue: queue, media: media, edge: .short) else {
                throw CLIError.calibrationFailed("长边和短边都没有得到正确的背面。请确认：整张纸翻到另一面、空白面朝上放回纸盒；如果 ② 印在 ① 同一面，说明放纸方向反了。")
            }
            flip = .short
            rotation = result
            print("短边测试通过：背面旋转 \(rotation)°。")
        }

        // 2) 两张：出纸堆叠顺序 → 背面顺序 + 空白位置
        print("\n[2/3] 页序测试（2 张纸）")
        let fronts = PDFBuilder.select(from: document, indices: [0, 2]) // FRONT 1, FRONT 3
        try printDocument(fronts, queue: queue, media: media, name: "cal fronts 1,3")

        let top = try Interaction.choice(
            "\n先不要翻整叠。只翻看最上面一张的正面：它是：",
            options: ["FRONT 1", "FRONT 3"]
        )
        let order: BackOrder = top == 1 ? .asc : .desc
        let blankSide: BlankSide = order == .asc ? .trailing : .leading
        print("根据出纸顺序，背面用 \(order.displayName)，奇数页空白补在\(blankSide.displayName)。")

        printFlipInstruction(flip: flip)
        try Interaction.pause("翻好并放回纸盒后按 Enter，开始打印背面。")

        let (_, back, _) = PDFBuilder.build(
            source: document,
            selected: [0, 1, 2, 3],
            order: order,
            blankSide: blankSide,
            rotation: rotation,
            offset: .zero
        )
        try printDocument(back, queue: queue, media: media, name: "cal backs")

        let verified = try Interaction.choice(
            "\n看成品：从上到下第 1 张应该是 1/2，第 2 张是 3/4，且背面文字正立。结果：",
            options: ["正确", "顺序不对（例如 3/4 在上面）", "背面倒置", "有页面印在同一面/错位"]
        )
        guard verified == 1 else {
            throw CLIError.calibrationFailed("页序/方向还不正确。可以再运行一次 hpduplex calibrate --force；如果只差顺序，可先用 print --back-order asc|desc 手动验证。")
        }

        // 3) 保存
        var result = current
        result.queue = queue.name
        result.flip = flip
        result.rotation = rotation
        result.backOrder = order
        result.blankSide = blankSide
        result.calibrated = true
        result.printerModel = queue.displayModel
        result.calibratedAt = Date()

        print("""

        [3/3] 校准完成
          翻面: \(flip.displayName)
          背面旋转: \(rotation)°
          背面顺序: \(order.displayName)
          空白位置: \(blankSide.displayName)

        如果背面有 1–3 mm 偏移，可以之后用 --offset X,Y 微调（单位 mm）。
        建议先运行：hpduplex print hp136w-sample.pdf --dry-run
        """)

        return result
    }

    /// 返回背面需要的旋转（0/180）；失败返回 nil。
    private static func determineFlip(
        document: PDFDocument,
        queue: PrintQueue,
        media: String,
        edge: FlipEdge
    ) throws -> Int? {
        for attempt in 1...2 {
            print("\n--- \(edge.displayName) 第 \(attempt) 次尝试 ---")

            let front = PDFBuilder.select(from: document, indices: [0])
            try printDocument(front, queue: queue, media: media, name: "cal front")

            let sideUp = try Interaction.choice(
                "现在朝上的一面是：",
                options: ["FRONT 1（有字）", "空白"]
            )

            let edgeWord = edge == .long ? "沿长边左右翻" : "沿短边上下翻"
            let instruction: String
            if attempt == 1 {
                if sideUp == 1 {
                    instruction = "请\(edgeWord)到另一面，让空白面朝上，放回纸盒。"
                } else {
                    instruction = "请保持空白面朝上（不要翻），直接放回纸盒。"
                }
            } else {
                if sideUp == 1 {
                    instruction = "请保持 FRONT 1 朝上（不要翻），直接放回纸盒。"
                } else {
                    instruction = "请\(edgeWord)到另一面，让 FRONT 1 朝上，放回纸盒。"
                }
            }

            try Interaction.pause("\(instruction) 按 Enter 继续。")

            let back = PDFBuilder.select(from: document, indices: [1])
            try printDocument(back, queue: queue, media: media, name: "cal back")

            let result = try Interaction.choice(
                "\n看这张纸的背面：",
                options: [
                    "② 正立，且在 ① 的背面",
                    "② 倒置 180°，但在 ① 的背面",
                    "② 印在 ① 的同一面 / 位置明显不对"
                ]
            )

            switch result {
            case 1:
                return 0
            case 2:
                return 180
            default:
                print("这次没有印到正确的背面，换一种放纸方向再试。")
                continue
            }
        }
        return nil
    }

    private static func printFlipInstruction(flip: FlipEdge) {
        print("\n=== 现在翻面 ===")
        print("1. 取出整叠纸，不要打散。")
        print("2. 看最上面一张：如果能看到正面文字，就把整叠翻面；如果看到的是空白，就直接放回。")
        switch flip {
        case .long:
            print("3. 需要翻时：沿长边左右翻，像合上书再翻到背面；保持纸的上下边不变。")
        case .short:
            print("3. 需要翻时：沿短边上下翻，像翻日历；纸的上下边对调。")
        }
        print("4. 把整叠放回纸盒（不要一张张翻），让空白面朝上。")
    }

    private static func printDocument(
        _ document: PDFDocument,
        queue: PrintQueue,
        media: String,
        name: String
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hpduplex-cal-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFBuilder.write(document, to: url)
        let job = try Printer.printFile(
            url.path,
            queue: queue.name,
            media: media,
            jobName: name
        )
        print("  已提交 \(job)，等待打印完成...")
        try Printer.waitForJob(id: job, queue: queue.name, timeout: 300)
    }
}