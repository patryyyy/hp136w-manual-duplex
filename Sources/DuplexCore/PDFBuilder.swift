import Foundation
import PDFKit
import AppKit
import CoreText

public enum PDFBuilderError: LocalizedError {
    case cannotOpen(String)
    case cannotCreatePDF
    case cannotWrite(String)
    case noPages

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path):
            return "打不开 PDF：\(path)"
        case .cannotCreatePDF:
            return "创建 PDF 失败"
        case .cannotWrite(let path):
            return "写入 PDF 失败：\(path)"
        case .noPages:
            return "PDF 没有页面"
        }
    }
}

public enum PDFBuilder {
    public static let a4 = CGSize(width: 595.276, height: 841.89)

    public static func load(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw PDFBuilderError.cannotOpen(url.path)
        }
        return document
    }

    public static func select(from source: PDFDocument, indices: [Int]) -> PDFDocument {
        let output = PDFDocument()
        for index in indices {
            if let page = source.page(at: index) {
                output.insert(page, at: output.pageCount)
            }
        }
        return output
    }

    /// 生成正面/背面两个文档。背面会按 order/blankSide 重排并在必要时补空白。
    public static func build(
        source: PDFDocument,
        selected: [Int],
        order: BackOrder,
        blankSide: BlankSide,
        rotation: Int,
        offset: CGPoint
    ) -> (front: PDFDocument, back: PDFDocument, plan: PagePlan) {
        let plan = PagePlan(selected: selected)
        let blankSize = source.page(at: selected[0])?.bounds(for: .mediaBox).size ?? a4

        let frontPages = plan.frontIndices.map { source.page(at: $0) }
        let front = makeDocument(
            pages: frontPages,
            rotation: 0,
            offset: .zero,
            blankSize: blankSize
        )

        if !plan.needsBackPass {
            return (front, PDFDocument(), plan)
        }

        let backPages = plan.backSequence(order: order, blankSide: blankSide).map { index in
            index.flatMap { source.page(at: $0) }
        }
        let back = makeDocument(
            pages: backPages,
            rotation: rotation,
            offset: offset,
            blankSize: blankSize
        )

        return (front, back, plan)
    }

    public static func write(_ document: PDFDocument, to url: URL) throws {
        guard document.pageCount > 0 else { throw PDFBuilderError.noPages }
        guard document.write(to: url) else {
            throw PDFBuilderError.cannotWrite(url.path)
        }
    }

    public static func pageSize(of document: PDFDocument) -> CGSize {
        document.page(at: 0)?.bounds(for: .mediaBox).size ?? a4
    }

    // MARK: - 文档构建

    private static func makeDocument(
        pages: [PDFPage?],
        rotation: Int,
        offset: CGPoint,
        blankSize: CGSize
    ) -> PDFDocument {
        let output = PDFDocument()

        let normalized = ((rotation % 360) + 360) % 360

        // 只有完全不旋转、不偏移时才直接搬运页面。
        // 旋转必须“烤”进页面内容：AirPrint/CUPS 会忽略 PDF 的 /Rotate 标记，
        // 只写 page.rotation 的话，实际打印出来不会转。
        if offset == .zero && normalized == 0 {
            for page in pages {
                guard let page else {
                    output.insert(blankPage(size: blankSize), at: output.pageCount)
                    continue
                }
                output.insert(page, at: output.pageCount)
            }
        } else {
            for page in pages {
                let size = page?.bounds(for: .mediaBox).size ?? blankSize
                output.insert(
                    renderPage(page, size: size, rotation: normalized, offset: offset),
                    at: output.pageCount
                )
            }
        }

        return output
    }

    private static func blankPage(size: CGSize) -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            fatalError("无法创建空白 PDF 页")
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data),
              let page = document.page(at: 0) else {
            fatalError("无法创建空白 PDF 页")
        }
        return page
    }

    private static func renderPage(
        _ page: PDFPage?,
        size: CGSize,
        rotation: Int,
        offset: CGPoint
    ) -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            fatalError("无法创建 PDF 页")
        }

        context.beginPDFPage(nil)
        context.saveGState()
        context.translateBy(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
        context.rotate(by: CGFloat(rotation) * .pi / 180.0)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        if let page {
            page.draw(with: .mediaBox, to: context)
        }
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data),
              let rendered = document.page(at: 0) else {
            fatalError("无法创建 PDF 页")
        }
        return rendered
    }

    // MARK: - 测试页/校准页

    public static func makeSamplePDF(pageCount: Int = 4) -> PDFDocument {
        let labels = (1...max(1, pageCount)).map { number in
            (title: "PAGE \(number)", subtitle: "TOP ↑")
        }
        return makeLabeledPDF(labels: labels)
    }

    public static func makeCalibrationPDF() -> PDFDocument {
        makeLabeledPDF(labels: [
            (title: "FRONT 1", subtitle: "side A · top ↑"),
            (title: "BACK 2", subtitle: "side B · top ↑"),
            (title: "FRONT 3", subtitle: "side A · top ↑"),
            (title: "BACK 4", subtitle: "side B · top ↑")
        ])
    }

    public static func makeLabeledPDF(labels: [(title: String, subtitle: String)]) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: a4)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            fatalError("无法创建校准 PDF")
        }

        for label in labels {
            context.beginPDFPage(nil)
            drawLabelPage(context, size: a4, title: label.title, subtitle: label.subtitle)
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            fatalError("无法创建校准 PDF")
        }
        return document
    }

    private static func drawLabelPage(
        _ context: CGContext,
        size: CGSize,
        title: String,
        subtitle: String
    ) {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(x: 36, y: 36, width: size.width - 72, height: size.height - 72))

        // 顶部箭头
        let centerX = size.width / 2
        context.setLineWidth(6)
        context.move(to: CGPoint(x: centerX, y: size.height - 64))
        context.addLine(to: CGPoint(x: centerX, y: size.height - 136))
        context.strokePath()

        context.setFillColor(NSColor.black.cgColor)
        context.move(to: CGPoint(x: centerX, y: size.height - 48))
        context.addLine(to: CGPoint(x: centerX - 18, y: size.height - 78))
        context.addLine(to: CGPoint(x: centerX + 18, y: size.height - 78))
        context.closePath()
        context.fillPath()

        drawCenteredText("TOP", fontSize: 26, weight: .semibold,
                         baselineY: size.height - 176, width: size.width, context: context)

        drawCenteredText(title, fontSize: 72, weight: .bold,
                         baselineY: size.height * 0.64, width: size.width, context: context)
        drawCenteredText(subtitle, fontSize: 24, weight: .regular,
                         baselineY: size.height * 0.57, width: size.width, context: context)

        // 中央十字线（用来检查背面偏移）
        let crossY = size.height * 0.36
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: centerX - 90, y: crossY))
        context.addLine(to: CGPoint(x: centerX + 90, y: crossY))
        context.move(to: CGPoint(x: centerX, y: crossY - 90))
        context.addLine(to: CGPoint(x: centerX, y: crossY + 90))
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: centerX - 22, y: crossY - 22, width: 44, height: 44))

        // 左上/右上角标记：用来快速判断纸张有没有被转 180°
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 52, y: size.height - 76, width: 16, height: 16))
        context.stroke(CGRect(x: size.width - 68, y: size.height - 76, width: 16, height: 16))

        drawCenteredText("HP Laser MFP 136w · manual duplex calibration",
                         fontSize: 13, weight: .regular,
                         baselineY: 58, width: size.width, context: context)
    }

    private static func drawCenteredText(
        _ text: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        baselineY: CGFloat,
        width: CGFloat,
        context: CGContext
    ) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: (width - bounds.width) / 2, y: baselineY)
        CTLineDraw(line, context)
    }
}