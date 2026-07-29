import Foundation

public enum TemperatureSensorGroup: String, Sendable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "内存"
    case system = "系统"

    var sortOrder: Int {
        switch self {
        case .cpu: return 0
        case .gpu: return 1
        case .memory: return 2
        case .system: return 3
        }
    }
}

public struct TemperatureReading: Identifiable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let group: TemperatureSensorGroup
    public let celsius: Double

    public var id: String { key }

    public init(
        key: String,
        name: String,
        group: TemperatureSensorGroup,
        celsius: Double
    ) {
        self.key = key
        self.name = name
        self.group = group
        self.celsius = celsius
    }
}

struct TemperatureSensorDefinition {
    let key: String
    let name: String
    let group: TemperatureSensorGroup
}

enum TemperatureSensorCatalog {
    static func definitions(for hardwareModel: String) -> [TemperatureSensorDefinition] {
        var definitions: [TemperatureSensorDefinition] = []

        if hardwareModel.hasPrefix("Mac15") || hardwareModel.hasPrefix("Mac14") {
            definitions += m3
        }

        definitions += crossPlatform
        return definitions
    }

    private static let m3: [TemperatureSensorDefinition] = [
        .init(key: "Te05", name: "能效核心 1", group: .cpu),
        .init(key: "Te0L", name: "能效核心 2", group: .cpu),
        .init(key: "Te0P", name: "能效核心 3", group: .cpu),
        .init(key: "Te0S", name: "能效核心 4", group: .cpu),
        .init(key: "Tf04", name: "性能核心 1", group: .cpu),
        .init(key: "Tf09", name: "性能核心 2", group: .cpu),
        .init(key: "Tf0A", name: "性能核心 3", group: .cpu),
        .init(key: "Tf0B", name: "性能核心 4", group: .cpu),
        .init(key: "Tf0D", name: "性能核心 5", group: .cpu),
        .init(key: "Tf0E", name: "性能核心 6", group: .cpu),
        .init(key: "Tf44", name: "性能核心 7", group: .cpu),
        .init(key: "Tf49", name: "性能核心 8", group: .cpu),
        .init(key: "Tf4A", name: "性能核心 9", group: .cpu),
        .init(key: "Tf4B", name: "性能核心 10", group: .cpu),
        .init(key: "Tf4D", name: "性能核心 11", group: .cpu),
        .init(key: "Tf4E", name: "性能核心 12", group: .cpu),
        .init(key: "Tf14", name: "图形核心 1", group: .gpu),
        .init(key: "Tf18", name: "图形核心 2", group: .gpu),
        .init(key: "Tf19", name: "图形核心 3", group: .gpu),
        .init(key: "Tf1A", name: "图形核心 4", group: .gpu),
        .init(key: "Tf24", name: "图形核心 5", group: .gpu),
        .init(key: "Tf28", name: "图形核心 6", group: .gpu),
        .init(key: "Tf29", name: "图形核心 7", group: .gpu),
        .init(key: "Tf2A", name: "图形核心 8", group: .gpu)
    ]

    private static let crossPlatform: [TemperatureSensorDefinition] = [
        .init(key: "TC0D", name: "CPU 二极管", group: .cpu),
        .init(key: "TC0E", name: "CPU 虚拟传感器", group: .cpu),
        .init(key: "TC0F", name: "CPU 滤波温度", group: .cpu),
        .init(key: "TC0H", name: "CPU 散热器", group: .cpu),
        .init(key: "TC0P", name: "CPU 邻近位置", group: .cpu),
        .init(key: "TCAD", name: "CPU 封装", group: .cpu),
        .init(key: "TG0D", name: "GPU 二极管", group: .gpu),
        .init(key: "TG0H", name: "GPU 散热器", group: .gpu),
        .init(key: "TG0P", name: "GPU 邻近位置", group: .gpu),
        .init(key: "Tm0P", name: "主板", group: .system),
        .init(key: "TW0P", name: "无线模块", group: .system),
        .init(key: "TL0P", name: "显示区域", group: .system),
        .init(key: "Ts0P", name: "系统传感器 1", group: .system),
        .init(key: "Ts1P", name: "系统传感器 2", group: .system),
        .init(key: "TB1T", name: "电池", group: .system)
    ]
}
