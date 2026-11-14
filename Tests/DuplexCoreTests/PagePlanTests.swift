import XCTest
import PDFKit
@testable import DuplexCore

final class PagePlanTests: XCTestCase {
    func testFrontBackSplit() {
        let plan = PagePlan(selected: [0, 1, 2, 3])
        XCTAssertEqual(plan.frontIndices, [0, 2])
        XCTAssertEqual(plan.backIndices, [1, 3])
        XCTAssertEqual(plan.sheetCount, 2)
        XCTAssertTrue(plan.needsBackPass)
    }

    func testOnePageHasNoBackPass() {
        let plan = PagePlan(selected: [0])
        XCTAssertEqual(plan.frontIndices, [0])
        XCTAssertTrue(plan.backIndices.isEmpty)
        XCTAssertFalse(plan.needsBackPass)
        XCTAssertEqual(plan.sheetCount, 1)
    }

    func testOddPageBlankDescLeading() {
        let plan = PagePlan(selected: [0, 1, 2, 3, 4])
        XCTAssertEqual(plan.backSequence(order: .desc, blankSide: .leading),
                       [nil, 3, 1])
        XCTAssertEqual(plan.backSequence(order: .desc, blankSide: .trailing),
                       [3, 1, nil])
    }

    func testOddPageBlankAscending() {
        let plan = PagePlan(selected: [0, 1, 2, 3, 4])
        XCTAssertEqual(plan.backSequence(order: .asc, blankSide: .trailing),
                       [1, 3, nil])
    }

    func testPageRangeParsing() throws {
        XCTAssertEqual(try PageRange.parse("1-3,5", pageCount: 6), [0, 1, 2, 4])
        XCTAssertEqual(try PageRange.parse("2-", pageCount: 3), [1, 2])
        XCTAssertEqual(try PageRange.parse("-2", pageCount: 4), [0, 1])
        XCTAssertEqual(try PageRange.parse(nil, pageCount: 2), [0, 1])
    }

    func testPageRangeRejectsBadInput() {
        XCTAssertThrowsError(try PageRange.parse("0", pageCount: 4))
        XCTAssertThrowsError(try PageRange.parse("5", pageCount: 4))
        XCTAssertThrowsError(try PageRange.parse("4-2", pageCount: 4))
        XCTAssertThrowsError(try PageRange.parse("abc", pageCount: 4))
    }

    func testPageLabels() {
        XCTAssertEqual(PagePlan.label(0), "1")
        XCTAssertEqual(PagePlan.label(nil), "空白")
    }

    func testRotationIsBakedIntoPageContent() {
        let source = PDFBuilder.makeSamplePDF(pageCount: 2)
        let (_, back, _) = PDFBuilder.build(
            source: source,
            selected: [0, 1],
            order: .desc,
            blankSide: .leading,
            rotation: 180,
            offset: .zero
        )
        XCTAssertEqual(back.pageCount, 1)
        // 旋转必须写进内容，而不是只留 /Rotate 标记；否则 AirPrint 打印不会转。
        XCTAssertEqual(back.page(at: 0)?.rotation, 0)
    }
}