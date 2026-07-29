import Foundation
import MacSMC

@main
enum CoolModeAlgorithmChecks {
    static func main() {
        var failures: [String] = []
        run("policies map the same load to increasing cooling demand", failures: &failures) {
            try policiesIncreaseCoolingDemandInConfiguredOrder()
        }
        run("CPU and GPU spikes raise predicted heat", failures: &failures) {
            try cpuAndGPUSpikeProducesHigherPredictedHeat()
        }
        run("temperature rise adds predictive cooling demand", failures: &failures) {
            try temperatureRiseAddsPredictiveCoolingDemand()
        }
        run("cooling demand falls gradually after load drops", failures: &failures) {
            try coolingDemandFallsGraduallyAfterLoadDrops()
        }
        run("memory and disk pressure add corrective demand", failures: &failures) {
            try memoryAndDiskPressureAddCorrectiveDemand()
        }
        run("fan targets stay within hardware limits", failures: &failures) {
            try fanTargetsStayWithinHardwareLimits()
        }
        run("temperature feedback identifies missing sensors", failures: &failures) {
            try temperatureFeedbackRequirement()
        }

        if failures.isEmpty {
            print("CoolModeAlgorithmChecks: 7 checks passed")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }

    private static func policiesIncreaseCoolingDemandInConfiguredOrder() throws {
        let input = sample(cpu: 72, gpu: 58, memory: 78, diskMBps: 36, cpuTemp: 66, gpuTemp: 63)

        let quiet = assess(input, policy: .quiet)
        let comfort = assess(input, policy: .comfort)
        let maximumCooling = assess(input, policy: .maximumCooling)

        try require(quiet.coolingDemand < comfort.coolingDemand, "expected quiet < comfort")
        try require(comfort.coolingDemand < maximumCooling.coolingDemand, "expected comfort < maximum cooling")
    }

    private static func cpuAndGPUSpikeProducesHigherPredictedHeat() throws {
        let idle = sample(cpu: 4, gpu: 2, memory: 46, diskMBps: 1, cpuTemp: 52, gpuTemp: 50)
        let spike = sample(cpu: 88, gpu: 76, memory: 72, diskMBps: 24, cpuTemp: 61, gpuTemp: 60)

        try require(
            assess(idle, policy: .comfort).predictedHeatScore
                < assess(spike, policy: .comfort).predictedHeatScore,
            "expected CPU/GPU spike to raise predicted heat"
        )
    }

    private static func temperatureRiseAddsPredictiveCoolingDemand() throws {
        var algorithm = CoolModeAlgorithm()
        _ = algorithm.assess(
            sample(cpu: 32, gpu: 18, memory: 58, diskMBps: 4, cpuTemp: 57, gpuTemp: 54),
            policy: .comfort
        )
        let rising = algorithm.assess(
            sample(cpu: 32, gpu: 18, memory: 58, diskMBps: 4, cpuTemp: 61, gpuTemp: 58),
            policy: .comfort
        )

        try require(rising.temperatureRise > 0, "expected positive temperature rise")
        try require(rising.predictedHeatScore > 35, "expected temperature trend to lift the prediction")
    }

    private static func coolingDemandFallsGraduallyAfterLoadDrops() throws {
        var smoothed = CoolModeAlgorithm()
        let high = sample(cpu: 94, gpu: 82, memory: 80, diskMBps: 45, cpuTemp: 74, gpuTemp: 70)
        let idle = sample(cpu: 2, gpu: 1, memory: 42, diskMBps: 0, cpuTemp: 52, gpuTemp: 50)

        _ = smoothed.assess(high, policy: .comfort)
        let afterDrop = smoothed.assess(idle, policy: .comfort)
        let directIdle = assess(idle, policy: .comfort)

        try require(afterDrop.coolingDemand > directIdle.coolingDemand, "expected slow ramp-down after a spike")
    }

    private static func memoryAndDiskPressureAddCorrectiveDemand() throws {
        let lowPressure = sample(cpu: 38, gpu: 18, memory: 44, diskMBps: 1, cpuTemp: 56, gpuTemp: 54)
        let highPressure = sample(cpu: 38, gpu: 18, memory: 94, diskMBps: 76, cpuTemp: 56, gpuTemp: 54)

        try require(
            assess(lowPressure, policy: .comfort).predictedHeatScore
                < assess(highPressure, policy: .comfort).predictedHeatScore,
            "expected memory and disk activity to correct the prediction upward"
        )
    }

    private static func fanTargetsStayWithinHardwareLimits() throws {
        let minimum = 1_350.0
        let maximum = 5_349.0

        try require(
            CoolModeFanTargetMapper.targetRPM(minimumRPM: minimum, maximumRPM: maximum, coolingDemand: -20) == minimum,
            "negative demand must clamp to the fan minimum"
        )
        try require(
            CoolModeFanTargetMapper.targetRPM(minimumRPM: minimum, maximumRPM: maximum, coolingDemand: 150) == maximum,
            "excessive demand must clamp to the fan maximum"
        )
        let midpoint = CoolModeFanTargetMapper.targetRPM(minimumRPM: minimum, maximumRPM: maximum, coolingDemand: 50)
        try require(midpoint > minimum && midpoint < maximum, "midpoint demand must stay inside hardware limits")
    }

    private static func temperatureFeedbackRequirement() throws {
        let input = CoolModeInput(
            cpuUsage: 20,
            gpuUsage: 10,
            memoryUsage: 40,
            diskBytesPerSecond: 0,
            cpuTemperature: nil,
            gpuTemperature: nil,
            systemTemperature: nil
        )

        try require(!input.hasTemperatureFeedback, "expected absent sensors to be detected")
    }

    private static func run(
        _ name: String,
        failures: inout [String],
        body: () throws -> Void
    ) {
        do {
            try body()
        } catch {
            failures.append("\(name): \(error.localizedDescription)")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message: message) }
    }

    private static func assess(_ input: CoolModeInput, policy: CoolModePolicy) -> CoolModeAssessment {
        var algorithm = CoolModeAlgorithm()
        return algorithm.assess(input, policy: policy)
    }

    private static func sample(
        cpu: Double,
        gpu: Double,
        memory: Double,
        diskMBps: Double,
        cpuTemp: Double,
        gpuTemp: Double
    ) -> CoolModeInput {
        CoolModeInput(
            cpuUsage: cpu,
            gpuUsage: gpu,
            memoryUsage: memory,
            diskBytesPerSecond: diskMBps * 1_000_000,
            cpuTemperature: cpuTemp,
            gpuTemperature: gpuTemp,
            systemTemperature: 48
        )
    }
}

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
