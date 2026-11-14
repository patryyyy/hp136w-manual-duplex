import Foundation

public struct PagePlan {
    /// 选中的页，0-based，保持用户给出的顺序。
    public let selected: [Int]

    public init(selected: [Int]) {
        precondition(!selected.isEmpty, "PagePlan 至少需要一页")
        self.selected = selected
    }

    public var pageCount: Int { selected.count }
    public var sheetCount: Int { (selected.count + 1) / 2 }
    public var needsBackPass: Bool { selected.count > 1 }

    /// 正面：第 1、3、5… 个选中页（0-based 偶数位）。
    public var frontIndices: [Int] {
        stride(from: 0, to: selected.count, by: 2).map { selected[$0] }
    }

    /// 背面：第 2、4、6… 个选中页（0-based 奇数位），尚未排序/补空白。
    public var backIndices: [Int] {
        stride(from: 1, to: selected.count, by: 2).map { selected[$0] }
    }

    /// 最终要送进打印机的背面页序列；nil 表示空白页。
    /// - order == .desc：先逆序，再按 blankSide 补空白。
    /// - order == .asc：先正序，再按 blankSide 补空白。
    public func backSequence(order: BackOrder, blankSide: BlankSide) -> [Int?] {
        var sequence: [Int?] = backIndices.map { $0 }
        if order == .desc {
            sequence.reverse()
        }
        if sequence.count < frontIndices.count {
            if blankSide == .leading {
                sequence.insert(nil, at: 0)
            } else {
                sequence.append(nil)
            }
        }
        return sequence
    }

    /// 给人类看的页码（1-based），nil 显示为“空白”。
    public static func label(_ index: Int?) -> String {
        guard let index else { return "空白" }
        return String(index + 1)
    }
}