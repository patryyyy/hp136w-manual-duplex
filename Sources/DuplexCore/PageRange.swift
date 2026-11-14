import Foundation

public enum PageRangeError: LocalizedError {
    case empty
    case invalidToken(String)
    case outOfBounds(String, Int)
    case reversed(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "页码范围为空"
        case .invalidToken(let token):
            return "无法解析页码：\(token)"
        case .outOfBounds(let token, let count):
            return "页码 \(token) 超出范围（文档共 \(count) 页）"
        case .reversed(let token):
            return "页码范围起点大于终点：\(token)"
        }
    }
}

public enum PageRange {
    /// 把 "1-5,8,10-" 解析成 0-based 索引数组。spec 为空表示全部页面。
    public static func parse(_ spec: String?, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw PageRangeError.empty }

        let trimmed = spec?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return Array(0..<pageCount)
        }

        var result: [Int] = []
        var seen = Set<Int>()

        for rawToken in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }

            let pieces = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            var start: Int
            var end: Int

            if pieces.count == 1 {
                guard let value = Int(pieces[0]) else { throw PageRangeError.invalidToken(token) }
                start = value
                end = value
            } else if pieces.count == 2 {
                if pieces[0].isEmpty {
                    start = 1
                } else {
                    guard let value = Int(pieces[0]) else { throw PageRangeError.invalidToken(token) }
                    start = value
                }
                if pieces[1].isEmpty {
                    end = pageCount
                } else {
                    guard let value = Int(pieces[1]) else { throw PageRangeError.invalidToken(token) }
                    end = value
                }
            } else {
                throw PageRangeError.invalidToken(token)
            }

            guard start >= 1, start <= pageCount, end >= 1, end <= pageCount else {
                throw PageRangeError.outOfBounds(token, pageCount)
            }
            guard start <= end else {
                throw PageRangeError.reversed(token)
            }

            for page in start...end {
                let index = page - 1
                if seen.insert(index).inserted {
                    result.append(index)
                }
            }
        }

        if result.isEmpty {
            throw PageRangeError.empty
        }
        return result
    }
}