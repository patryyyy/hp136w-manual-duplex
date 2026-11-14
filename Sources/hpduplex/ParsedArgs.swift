import Foundation

public struct ParsedArgs {
    public var command: String?
    public var positional: [String] = []
    public var options: [String: String] = [:]
    public var flags: Set<String> = []

    public static let valueOptions: Set<String> = [
        "queue", "pages", "copies", "flip", "rotate", "rotation",
        "back-order", "blank", "media", "timeout", "auto-continue",
        "offset", "out", "set", "config", "spool", "interval"
    ]

    public static let flagOptions: Set<String> = [
        "help", "dry-run", "yes", "keep", "open", "force",
        "reset", "verbose", "calibration", "gui", "once"
    ]

    public static func parse(_ arguments: [String]) throws -> ParsedArgs {
        var parsed = ParsedArgs()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            if argument == "-h" {
                parsed.flags.insert("help")
                index += 1
                continue
            }

            if argument.hasPrefix("--") {
                let body = String(argument.dropFirst(2))
                if body.isEmpty {
                    throw CLIError.invalidArgument(argument)
                }

                if let equals = body.firstIndex(of: "=") {
                    let key = String(body[..<equals])
                    let value = String(body[body.index(after: equals)...])
                    guard valueOptions.contains(key) else {
                        throw CLIError.invalidArgument(argument)
                    }
                    parsed.options[key] = value
                } else if valueOptions.contains(body) {
                    guard index + 1 < arguments.count else {
                        throw CLIError.missingValue("--\(body)")
                    }
                    index += 1
                    parsed.options[body] = arguments[index]
                } else if flagOptions.contains(body) {
                    parsed.flags.insert(body)
                } else {
                    throw CLIError.invalidArgument(argument)
                }
            } else if argument.hasPrefix("-") && argument != "-" {
                throw CLIError.invalidArgument(argument)
            } else {
                if parsed.command == nil {
                    parsed.command = argument
                } else {
                    parsed.positional.append(argument)
                }
            }

            index += 1
        }

        return parsed
    }

    public func value(_ key: String) -> String? {
        options[key]
    }

    public func flag(_ key: String) -> Bool {
        flags.contains(key)
    }
}

public enum CLIError: LocalizedError {
    case invalidArgument(String)
    case missingValue(String)
    case unknownCommand(String)
    case missingPDF
    case notInteractive
    case calibrationFailed(String)
    case invalidValue(String)
    case canceled

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let argument):
            return "未知参数：\(argument)"
        case .missingValue(let option):
            return "参数 \(option) 缺少值"
        case .unknownCommand(let command):
            return "未知命令：\(command)（用 --help 查看用法）"
        case .missingPDF:
            return "请提供 PDF 文件路径"
        case .notInteractive:
            return "当前不是交互式终端；校准需要在终端里运行"
        case .calibrationFailed(let message):
            return "校准失败：\(message)"
        case .invalidValue(let message):
            return "参数值无效：\(message)"
        case .canceled:
            return "用户取消了打印"
        }
    }
}