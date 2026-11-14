import Foundation
import Darwin
import DuplexCore

public enum Interaction {
    public static var isTTY: Bool {
        isatty(STDIN_FILENO) == 1
    }

    public static func confirm(_ prompt: String, defaultYes: Bool = true) -> Bool {
        let suffix = defaultYes ? " [Y/n] " : " [y/N] "
        print(prompt + suffix, terminator: "")
        guard let line = readLine() else { return false }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if answer.isEmpty { return defaultYes }
        return ["y", "yes", "是", "好", "继续"].contains(answer)
    }

    public static func pause(_ prompt: String) throws {
        guard isTTY else { throw CLIError.notInteractive }
        print(prompt, terminator: "")
        _ = readLine()
    }

    public static func ask(_ prompt: String) throws -> String {
        guard isTTY else { throw CLIError.notInteractive }
        print(prompt, terminator: "")
        guard let line = readLine() else { throw CLIError.notInteractive }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用 macOS 对话框问“继续/取消”，供 CUPS backend / 无终端场景使用。
    public static func guiConfirm(_ message: String) -> Bool {
        let script = "display dialog \"\(escape(message))\" with title \"HP 136w 手动双面\" buttons {\"取消\", \"继续\"} default button \"继续\" with icon caution"
        let result = Shell.run("/usr/bin/osascript", ["-e", script])
        guard result.ok else { return false }
        return result.stdout.contains("继续")
    }

    public static func guiAlert(_ title: String, _ message: String) {
        let script = "display alert \"\(escape(title))\" message \"\(escape(message))\" as critical"
        _ = Shell.run("/usr/bin/osascript", ["-e", script])
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    public static func choice(_ prompt: String, options: [String]) throws -> Int {
        guard !options.isEmpty else { return 0 }
        while true {
            print(prompt)
            for (index, option) in options.enumerated() {
                print("  \(index + 1)) \(option)")
            }
            print("选择 [1-\(options.count)]：", terminator: "")
            guard let line = readLine() else { throw CLIError.notInteractive }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed), value >= 1, value <= options.count {
                return value
            }
            print("请输入 1 到 \(options.count) 之间的数字。")
        }
    }
}