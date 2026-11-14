import Foundation

public struct CommandResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var ok: Bool { status == 0 }
    public var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum Shell {
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

public struct PrintQueue: Identifiable, Equatable {
    public let name: String
    public let uri: String
    public let ppdPath: String
    public let model: String?
    public let nickname: String?

    public var id: String { name }

    public var displayModel: String {
        model ?? nickname ?? "未知型号"
    }

    public var is136w: Bool {
        let haystack = [name, uri, model ?? "", nickname ?? ""]
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("136w")
            || haystack.contains("131 133 135")
            || haystack.contains("131_133_135")
            || haystack.contains("hp040e3c87f240")
    }

    public var hasPPD: Bool {
        FileManager.default.fileExists(atPath: ppdPath)
    }
}

public enum PrinterError: LocalizedError {
    case commandFailed(String, String)
    case cannotParseJobID(String)
    case timeout(String, TimeInterval)
    case jobDisappeared(String)
    case jobCanceled(String)
    case jobAborted(String)
    case queueNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let message):
            return "\(command) 失败：\(message)"
        case .cannotParseJobID(let output):
            return "无法从 lp 输出中解析 job id：\(output)"
        case .timeout(let jobID, let seconds):
            return "等待打印任务 \(jobID) 超时（\(Int(seconds)) 秒）"
        case .jobDisappeared(let jobID):
            return "打印任务 \(jobID) 消失了（可能被取消或队列被清空）"
        case .jobCanceled(let jobID):
            return "打印任务 \(jobID) 被取消"
        case .jobAborted(let jobID):
            return "打印任务 \(jobID) 被中止（打印机错误/卡纸/缺纸？）"
        case .queueNotFound(let name):
            return "找不到打印队列：\(name)"
        }
    }
}

public enum Printer {
    public static func queues() -> [PrintQueue] {
        let result = Shell.run("/usr/bin/lpstat", ["-v"])
        guard result.ok else { return [] }

        let schemes = [
            "dnssd://", "ipps://", "ipp://", "usb://", "socket://", "lpd://",
            "smb://", "https://", "http://", "hpfax:/", "hp:/", "file:/",
            "bluetooth://"
        ]

        var queues: [PrintQueue] = []
        for line in result.stdout.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }
            // macOS 的 CUPS 会跟随系统语言输出中文（“用于X的设备：...”），
            // 这里不依赖固定前缀，而是从 URI scheme 反推队列名。
            guard let schemeRange = schemes
                .compactMap({ line.range(of: $0) })
                .min(by: { $0.lowerBound < $1.lowerBound }) else {
                continue
            }

            let prefix = String(line[..<schemeRange.lowerBound])
            let uri = String(line[schemeRange.lowerBound...])

            var name = prefix
            name = name.replacingOccurrences(of: "device for ", with: "")
            name = name.replacingOccurrences(of: "用于", with: "")
            name = name.replacingOccurrences(of: "的设备", with: "")
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = name.last, last == ":" || last == "：" || last == " " {
                name.removeLast()
            }

            guard !name.isEmpty, !uri.isEmpty else { continue }

            let ppdPath = "/etc/cups/ppd/\(name).ppd"
            queues.append(
                PrintQueue(
                    name: name,
                    uri: uri,
                    ppdPath: ppdPath,
                    model: ppdValue(ppdPath, key: "ModelName"),
                    nickname: ppdValue(ppdPath, key: "NickName")
                )
            )
        }
        return queues
    }

    public static func discover136w() -> [PrintQueue] {
        queues().filter(\.is136w)
    }

    public static func queue(named name: String) -> PrintQueue? {
        queues().first { $0.name == name }
    }

    public static func printFile(
        _ path: String,
        queue: String,
        media: String?,
        jobName: String
    ) throws -> String {
        var arguments = [
            "-d", queue,
            "-o", "sides=one-sided",
            "-o", "job-name=\(jobName)"
        ]
        if let media, !media.isEmpty, media.lowercased() != "auto" {
            arguments += ["-o", "media=\(media)"]
        }
        arguments.append(path)

        let result = Shell.run("/usr/bin/lp", arguments)
        guard result.ok else {
            throw PrinterError.commandFailed("lp", result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        if let range = result.stdout.range(of: "request id is ") {
            let tail = result.stdout[range.upperBound...]
            if let id = tail.split(separator: " ").first.map(String.init), !id.isEmpty {
                return id
            }
        }

        // 本地化输出（例如中文“请求 ID 为 ...”）：直接匹配 <queue>-<数字>。
        let pattern = NSRegularExpression.escapedPattern(for: queue) + "-(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let text = result.stdout
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let jobRange = Range(match.range, in: text) {
                return String(text[jobRange])
            }
        }

        throw PrinterError.cannotParseJobID(result.stdout)
    }

    public static func waitForJob(
        id: String,
        queue: String,
        timeout: TimeInterval = 300,
        poll: TimeInterval = 0.5
    ) throws {
        let started = Date()
        var missingSince: Date?

        while Date().timeIntervalSince(started) < timeout {
            let active = jobIDs(["-W", "not-completed", "-o", queue])
            if active.contains(id) {
                missingSince = nil
                Thread.sleep(forTimeInterval: poll)
                continue
            }

            let completed = jobIDs(["-W", "completed", "-o", queue])
            if completed.contains(id) {
                switch jobOutcome(jobID: id) {
                case .completed, .none:
                    return
                case .canceled:
                    throw PrinterError.jobCanceled(id)
                case .aborted:
                    throw PrinterError.jobAborted(id)
                }
            }

            if missingSince == nil {
                missingSince = Date()
            }
            if let missingSince, Date().timeIntervalSince(missingSince) > 5 {
                throw PrinterError.jobDisappeared(id)
            }
            Thread.sleep(forTimeInterval: poll)
        }

        throw PrinterError.timeout(id, timeout)
    }

    public static func status(queue: String) -> String {
        let result = Shell.run("/usr/bin/lpstat", ["-p", queue])
        return result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isStopped(queue: String) -> Bool {
        let status = status(queue: queue).lowercased()
        let needles = ["disabled", "stopped", "已禁用", "已停止", "停用", "禁用"]
        return needles.contains { status.contains($0) }
    }

    public static func cancel(jobID: String) -> CommandResult {
        Shell.run("/usr/bin/cancel", [jobID])
    }

    public enum JobOutcome {
        case completed
        case canceled
        case aborted
    }

    /// 用 CUPS 的 Get-Job-Attributes 确认最终状态；ipptool 不可用时返回 nil。
    public static func jobOutcome(jobID: String) -> JobOutcome? {
        guard let number = jobNumber(jobID) else { return nil }
        let result = Shell.run(
            "/usr/bin/ipptool",
            [
                "-tv",
                "ipp://127.0.0.1:631/jobs/\(number)",
                "/usr/share/cups/ipptool/get-job-attributes.test"
            ]
        )
        guard result.ok else { return nil }

        guard let range = result.stdout.range(of: "job-state (enum) = ") else { return nil }
        let tail = result.stdout[range.upperBound...]
        guard let value = tail.split(separator: "\n").first?
            .trimmingCharacters(in: .whitespaces) else {
            return nil
        }

        switch value {
        case "completed":
            return .completed
        case "canceled":
            return .canceled
        case "aborted":
            return .aborted
        default:
            return nil
        }
    }

    private static func jobNumber(_ jobID: String) -> Int? {
        guard let last = jobID.split(separator: "-").last else { return nil }
        return Int(last)
    }

    private static func jobIDs(_ arguments: [String]) -> Set<String> {
        let result = Shell.run("/usr/bin/lpstat", arguments)
        var ids = Set<String>()
        for line in result.stdout.components(separatedBy: .newlines) {
            let token = line.split(separator: " ").first.map(String.init) ?? ""
            if token.contains("-") {
                ids.insert(token)
            }
        }
        return ids
    }

    private static func ppdValue(_ path: String, key: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let pattern = "\\*\(key):\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }
}