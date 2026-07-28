import Darwin
import Foundation
import MacSMC
import Security

private enum HelperCommand {
    case status
    case temperatureKeys

    init(arguments: [String]) throws {
        guard arguments.count == 2 else {
            throw HelperError.usage
        }

        switch arguments[1] {
        case "status":
            self = .status
        case "temperature-keys":
            self = .temperatureKeys
        default:
            throw HelperError.usage
        }
    }
}

private enum HelperError: LocalizedError {
    case rootRequired
    case untrustedClient
    case usage

    var errorDescription: String? {
        switch self {
        case .rootRequired:
            return "风扇控制服务必须由 macOS 以管理员身份启动"
        case .untrustedClient:
            return "拒绝了未通过代码签名验证的客户端"
        case .usage:
            return "用法：MacFanHelper status | temperature-keys"
        }
    }
}

private final class FanControlService: NSObject, FanControlXPCProtocol {
    private let queue = DispatchQueue(
        label: "local.Mac-TaskManager.FanHelper.operations",
        qos: .userInitiated
    )
    private let coolModeHeartbeatTimeout: TimeInterval = 10
    private var coolModeFanIndexes = Set<Int>()
    private var lastCoolModeTargets: [Int: Double] = [:]
    private var lastCoolModeHeartbeat: Date?
    private var watchdog: DispatchSourceTimer?

    override init() {
        super.init()

        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            self?.restoreAutomaticAfterHeartbeatTimeoutIfNeeded()
        }
        watchdog.resume()
        self.watchdog = watchdog
    }

    deinit {
        watchdog?.cancel()
    }

    var hasActiveCoolMode: Bool {
        queue.sync {
            !coolModeFanIndexes.isEmpty
        }
    }

    func ping(withReply reply: @escaping (Bool, String?) -> Void) {
        reply(true, nil)
    }

    func setFanRPM(
        index: Int,
        rpm: Double,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.restoreCoolModeFansIfNeeded()
                try SMCController().setFanRPM(index: index, rpm: rpm)
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func setFanAutomatic(
        index: Int,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.restoreCoolModeFansIfNeeded()
                try SMCController().setFanAutomatic(index: index)
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func updateCoolModeTargets(
        indexes: [NSNumber],
        rpms: [NSNumber],
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !indexes.isEmpty, indexes.count == rpms.count else {
                reply(false, "清凉模式没有收到有效的风扇目标转速。")
                return
            }

            do {
                let controller = try SMCController()
                for (indexValue, rpmValue) in zip(indexes, rpms) {
                    let index = indexValue.intValue
                    let rpm = rpmValue.doubleValue
                    let previousRPM = self.lastCoolModeTargets[index]

                    if previousRPM.map({ abs($0 - rpm) >= 50 }) ?? true {
                        try controller.setFanRPM(index: index, rpm: rpm)
                        self.lastCoolModeTargets[index] = rpm
                    }
                    self.coolModeFanIndexes.insert(index)
                }
                self.lastCoolModeHeartbeat = Date()
                reply(true, nil)
            } catch {
                // A target batch can fail after an earlier fan was changed.
                // Never leave that partial batch in manual mode without a
                // heartbeat: immediately return every tracked fan to macOS.
                try? self.restoreCoolModeFansIfNeeded()
                reply(false, error.localizedDescription)
            }
        }
    }

    func stopCoolMode(withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.restoreCoolModeFansIfNeeded()
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    private func restoreAutomaticAfterHeartbeatTimeoutIfNeeded() {
        guard let lastCoolModeHeartbeat,
              Date().timeIntervalSince(lastCoolModeHeartbeat) >= coolModeHeartbeatTimeout,
              !coolModeFanIndexes.isEmpty else {
            return
        }

        do {
            try restoreCoolModeFansIfNeeded()
        } catch {
            // Keep the mode marked active and retry after another timeout.
            self.lastCoolModeHeartbeat = Date()
        }
    }

    private func restoreCoolModeFansIfNeeded() throws {
        guard !coolModeFanIndexes.isEmpty else {
            lastCoolModeHeartbeat = nil
            lastCoolModeTargets = [:]
            return
        }

        let controller = try SMCController()
        for index in coolModeFanIndexes.sorted() {
            try controller.setFanAutomatic(index: index)
        }
        coolModeFanIndexes = []
        lastCoolModeTargets = [:]
        lastCoolModeHeartbeat = nil
    }
}

private final class FanControlListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = FanControlService()
    private let clientRequirement: SecRequirement?

    var hasActiveCoolMode: Bool {
        service.hasActiveCoolMode
    }

    override init() {
        clientRequirement = Self.makeClientRequirement()
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard let clientRequirement,
              Self.isTrusted(newConnection, requirement: clientRequirement) else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(
            with: FanControlXPCProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }

    private static func makeClientRequirement() -> SecRequirement? {
        guard let teamIdentifier = currentTeamIdentifier() else {
            return nil
        }

        let requirementText =
            "anchor apple generic and identifier \"\(FanControlXPC.mainApplicationIdentifier)\" " +
            "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        )
        guard status == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static func currentTeamIdentifier() -> String? {
        var dynamicCode: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let dynamicCode,
              SecCodeCopyStaticCode(
            dynamicCode,
            [],
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var signingInformation: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard status == errSecSuccess,
              let information = signingInformation as? [CFString: Any] else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier] as? String
    }

    private static func isTrusted(
        _ connection: NSXPCConnection,
        requirement: SecRequirement
    ) -> Bool {
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &guestCode
        ) == errSecSuccess,
              let guestCode else {
            return false
        }

        return SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess
    }
}

private func runDaemon() throws -> Never {
    guard geteuid() == 0 else {
        throw HelperError.rootRequired
    }

    let delegate = FanControlListenerDelegate()
    let listener = NSXPCListener(machServiceName: FanControlXPC.serviceName)
    listener.delegate = delegate
    listener.resume()

    func exitWhenIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if delegate.hasActiveCoolMode {
                exitWhenIdle()
            } else {
                exit(EXIT_SUCCESS)
            }
        }
    }
    exitWhenIdle()

    withExtendedLifetime(delegate) {
        RunLoop.current.run()
    }
    fatalError("风扇控制服务意外退出")
}

private func runCommandLineTool() throws {
    let command = try HelperCommand(arguments: CommandLine.arguments)
    let controller = try SMCController()

    switch command {
    case .status:
        let snapshot = try controller.snapshot()
        print("model=\(snapshot.hardwareModel) fans=\(snapshot.fans.count)")
        for fan in snapshot.fans {
            print(
                "fan=\(fan.index) actual=\(Int(fan.actualRPM)) target=\(Int(fan.targetRPM)) " +
                "minimum=\(Int(fan.minimumRPM)) maximum=\(Int(fan.maximumRPM)) " +
                "mode=\(fan.isManual ? "manual" : "automatic")"
            )
        }
        print("temperatures=\(snapshot.temperatures.count)")
        for sensor in snapshot.temperatures {
            print(
                "sensor=\(sensor.key) group=\(sensor.group.rawValue) " +
                "name=\(sensor.name) celsius=\(String(format: "%.1f", sensor.celsius))"
            )
        }
    case .temperatureKeys:
        for sensor in controller.availableTemperatureKeys() {
            print("\(sensor.key)=\(String(format: "%.1f", sensor.celsius))")
        }
    }
}

do {
    if CommandLine.arguments.count == 1 {
        try runDaemon()
    } else {
        try runCommandLineTool()
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
