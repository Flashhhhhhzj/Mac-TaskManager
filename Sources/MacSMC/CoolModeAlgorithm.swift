import Foundation

public enum CoolModePolicy: String, CaseIterable, Sendable {
    case comfort = "舒适优先"
    case quiet = "静音平衡"
    case maximumCooling = "极致降温"

    public var subtitle: String {
        switch self {
        case .comfort:
            return "提前散热，兼顾键盘温度与风噪"
        case .quiet:
            return "在明显升温时再提高风扇转速"
        case .maximumCooling:
            return "优先压低温升，允许更高风扇转速"
        }
    }
}

public enum CoolModeHeatLevel: String, Equatable, Sendable {
    case low
    case medium
    case high

    public var title: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

public struct CoolModeInput: Equatable, Sendable {
    public let cpuUsage: Double
    public let gpuUsage: Double
    public let memoryUsage: Double
    public let diskBytesPerSecond: Double
    public let cpuTemperature: Double?
    public let gpuTemperature: Double?
    public let systemTemperature: Double?

    public init(
        cpuUsage: Double,
        gpuUsage: Double,
        memoryUsage: Double,
        diskBytesPerSecond: Double,
        cpuTemperature: Double?,
        gpuTemperature: Double?,
        systemTemperature: Double?
    ) {
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.memoryUsage = memoryUsage
        self.diskBytesPerSecond = diskBytesPerSecond
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.systemTemperature = systemTemperature
    }

    public var hasTemperatureFeedback: Bool {
        highestTemperature != nil
    }

    public var highestTemperature: Double? {
        [cpuTemperature, gpuTemperature, systemTemperature]
            .compactMap { $0 }
            .filter { $0 > 0 }
            .max()
    }
}

public struct CoolModeAssessment: Equatable, Sendable {
    public let heatLevel: CoolModeHeatLevel
    public let predictedHeatScore: Double
    public let coolingDemand: Double
    public let dominantFactor: String
    public let highestTemperature: Double
    public let temperatureRise: Double

    public init(
        heatLevel: CoolModeHeatLevel,
        predictedHeatScore: Double,
        coolingDemand: Double,
        dominantFactor: String,
        highestTemperature: Double,
        temperatureRise: Double
    ) {
        self.heatLevel = heatLevel
        self.predictedHeatScore = predictedHeatScore
        self.coolingDemand = coolingDemand
        self.dominantFactor = dominantFactor
        self.highestTemperature = highestTemperature
        self.temperatureRise = temperatureRise
    }
}

/// Converts a cooling demand into a target that is safe for an individual fan.
/// Keeping this mapping independent of the UI makes the hardware bounds
/// explicit and directly verifiable.
public enum CoolModeFanTargetMapper {
    public static func targetRPM(
        minimumRPM: Double,
        maximumRPM: Double,
        coolingDemand: Double
    ) -> Double {
        guard maximumRPM >= minimumRPM else { return minimumRPM.rounded() }
        let demand = min(max(coolingDemand, 0), 100) / 100
        let target = minimumRPM + (maximumRPM - minimumRPM) * demand
        return min(max(target, minimumRPM), maximumRPM).rounded()
    }
}

/// A deterministic, short-horizon thermal-load predictor. CPU and GPU are the
/// primary heat sources; unified-memory pressure and storage activity are
/// secondary signals. SMC temperature and its rising trend provide feedback so
/// the controller can start cooling before the reported temperature peaks.
public struct CoolModeAlgorithm: Sendable {
    private var previousTemperature: Double?
    private var previousDemand: Double?

    public init() {}

    public mutating func reset() {
        previousTemperature = nil
        previousDemand = nil
    }

    public mutating func assess(
        _ input: CoolModeInput,
        policy: CoolModePolicy
    ) -> CoolModeAssessment {
        let cpu = normalizedPercent(input.cpuUsage)
        let gpu = normalizedPercent(input.gpuUsage)
        let memory = unitClamp((normalizedPercent(input.memoryUsage) - 0.55) / 0.45)
        let disk = unitClamp(input.diskBytesPerSecond / 80_000_000)

        let workload = (cpu * 0.46 + gpu * 0.36 + memory * 0.10 + disk * 0.08) * 100
        let highestTemperature = input.highestTemperature ?? 0
        let temperatureScore = unitClamp((highestTemperature - 45) / 40) * 100
        let temperatureRise = max(highestTemperature - (previousTemperature ?? highestTemperature), 0)
        let risingBonus = min(temperatureRise * 8, 24)
        let predictedHeat = scoreClamp(workload * 0.58 + temperatureScore * 0.42 + risingBonus)
        let requestedDemand = demand(for: predictedHeat, policy: policy)
        let coolingDemand = smooth(requestedDemand, policy: policy)

        previousTemperature = highestTemperature > 0 ? highestTemperature : previousTemperature

        return CoolModeAssessment(
            heatLevel: heatLevel(for: predictedHeat),
            predictedHeatScore: predictedHeat,
            coolingDemand: coolingDemand,
            dominantFactor: dominantFactor(
                cpu: cpu,
                gpu: gpu,
                memory: memory,
                disk: disk,
                temperatureRise: temperatureRise
            ),
            highestTemperature: highestTemperature,
            temperatureRise: temperatureRise
        )
    }

    private mutating func smooth(_ requestedDemand: Double, policy: CoolModePolicy) -> Double {
        guard let previousDemand else {
            self.previousDemand = requestedDemand
            return requestedDemand
        }

        let difference = requestedDemand - previousDemand
        if abs(difference) < 4 {
            return previousDemand
        }

        let riseLimit: Double
        let fallLimit: Double
        switch policy {
        case .quiet:
            riseLimit = 18
            fallLimit = 6
        case .comfort:
            riseLimit = 26
            fallLimit = 8
        case .maximumCooling:
            riseLimit = 36
            fallLimit = 10
        }

        let smoothed: Double
        if difference > 0 {
            smoothed = min(previousDemand + riseLimit, requestedDemand)
        } else {
            smoothed = max(previousDemand - fallLimit, requestedDemand)
        }
        self.previousDemand = smoothed
        return smoothed
    }

    private func demand(for predictedHeat: Double, policy: CoolModePolicy) -> Double {
        switch policy {
        case .quiet:
            return scoreClamp(max(predictedHeat - 18, 0) * 0.72)
        case .comfort:
            return scoreClamp(max(predictedHeat - 10, 0) * 0.92 + 8)
        case .maximumCooling:
            return scoreClamp(max(predictedHeat - 4, 0) * 1.05 + 18)
        }
    }

    private func heatLevel(for score: Double) -> CoolModeHeatLevel {
        if score >= 62 { return .high }
        if score >= 30 { return .medium }
        return .low
    }

    private func dominantFactor(
        cpu: Double,
        gpu: Double,
        memory: Double,
        disk: Double,
        temperatureRise: Double
    ) -> String {
        let factors: [(String, Double)] = [
            ("CPU 负载", cpu * 0.46),
            ("GPU 负载", gpu * 0.36),
            ("内存占用", memory * 0.10),
            ("磁盘吞吐", disk * 0.08),
            ("温度上升", min(temperatureRise / 3, 1) * 0.42)
        ]
        return factors.max(by: { $0.1 < $1.1 })?.0 ?? "系统负载"
    }

    private func normalizedPercent(_ value: Double) -> Double {
        unitClamp(value / 100)
    }

    private func unitClamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func scoreClamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
