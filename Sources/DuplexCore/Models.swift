import Foundation

public enum FlipEdge: String, Codable, CaseIterable {
    case long
    case short

    public var displayName: String {
        switch self {
        case .long: return "长边（像翻书）"
        case .short: return "短边（像翻日历）"
        }
    }
}

public enum BackOrder: String, Codable, CaseIterable {
    case asc
    case desc

    public var displayName: String {
        switch self {
        case .asc: return "正序"
        case .desc: return "逆序"
        }
    }
}

public enum BlankSide: String, Codable, CaseIterable {
    case leading
    case trailing

    public var displayName: String {
        switch self {
        case .leading: return "开头"
        case .trailing: return "结尾"
        }
    }
}

public struct DuplexConfig: Codable {
    /// 上次使用的队列名；为空时自动发现 136w。
    public var queue: String?
    public var flip: FlipEdge
    /// 0 或 180
    public var rotation: Int
    public var backOrder: BackOrder
    public var blankSide: BlankSide
    /// 背面内容相对正面在 PDF 坐标中的偏移（mm）；仅高级手动调整用。
    public var offsetX: Double
    public var offsetY: Double
    public var media: String
    public var calibrated: Bool
    public var printerModel: String?
    public var calibratedAt: Date?

    public init(
        queue: String? = nil,
        flip: FlipEdge = .long,
        rotation: Int = 0,
        backOrder: BackOrder = .desc,
        blankSide: BlankSide = .leading,
        offsetX: Double = 0,
        offsetY: Double = 0,
        media: String = "A4",
        calibrated: Bool = false,
        printerModel: String? = nil,
        calibratedAt: Date? = nil
    ) {
        self.queue = queue
        self.flip = flip
        self.rotation = rotation
        self.backOrder = backOrder
        self.blankSide = blankSide
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.media = media
        self.calibrated = calibrated
        self.printerModel = printerModel
        self.calibratedAt = calibratedAt
    }

    public static let `default` = DuplexConfig()

    public var normalizedRotation: Int {
        ((rotation % 360) + 360) % 360
    }
}

public enum ConfigStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HP136wDuplex", isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    public static func load(from url: URL? = nil) -> DuplexConfig {
        let target = url ?? fileURL
        guard let data = try? Data(contentsOf: target) else { return .default }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DuplexConfig.self, from: data)) ?? .default
    }

    public static func save(_ config: DuplexConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}