import AppKit
import Foundation
import MacSMC
import ServiceManagement
import SwiftUI

enum FanHelperAuthorizationState: Equatable {
    case checking
    case notRegistered
    case needsUpdate
    case requiresApproval
    case enabled
    case unavailable(String)

    var isEnabled: Bool {
        self == .enabled
    }
}

enum CoolModeState: Equatable {
    case off
    case starting
    case active
    case stopping
    case failed(String)

    var keepsControlLoopAlive: Bool {
        switch self {
        case .starting, .active, .stopping:
            return true
        case .off, .failed:
            return false
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .stopping:
            return true
        case .off, .active, .failed:
            return false
        }
    }

    var isEnabled: Bool {
        switch self {
        case .starting, .active, .stopping:
            return true
        case .off, .failed:
            return false
        }
    }

    /// The interface intentionally exposes only two appearances: inactive or
    /// active. The internal starting/stopping states are retained solely to
    /// protect the hardware handoff and must never alter the button label.
    var isButtonActive: Bool {
        switch self {
        case .starting, .active:
            return true
        case .stopping, .off, .failed:
            return false
        }
    }

    var buttonTitle: String {
        "清凉模式"
    }
}

enum CoolModePreferences {
    static let policyKey = "CoolModePolicy"

    static var currentPolicy: CoolModePolicy {
        guard let rawValue = UserDefaults.standard.string(forKey: policyKey),
              let policy = CoolModePolicy(rawValue: rawValue) else {
            return .comfort
        }
        return policy
    }
}

final class FanControlModel: ObservableObject {
    @Published var fans: [FanReading] = []
    @Published var temperatures: [TemperatureReading] = []
    @Published private(set) var temperatureHistories: [String: [Double]] = [:]
    @Published var hardwareModel = "正在识别 Mac…"
    @Published var isLoading = true
    @Published var busyFanIndex: Int?
    @Published var errorMessage: String?
    @Published var availabilityMessage = "正在检测 AppleSMC 风扇信息。"
    @Published var noticeMessage: String?
    @Published var helperAuthorizationState: FanHelperAuthorizationState = .checking
    @Published var isRegisteringHelper = false
    @Published private(set) var coolModeState: CoolModeState = .off
    @Published private(set) var coolModeAssessment: CoolModeAssessment?
    @Published private(set) var coolModeTargets: [Int: Double] = [:]
    @Published private(set) var coolModePolicy: CoolModePolicy

    private let monitor: SystemMonitor
    private let monitoringLogs: MonitoringLogRecorder
    private let queue = DispatchQueue(label: "Mac-TaskManager.fan-control", qos: .userInitiated)
    private let temperatureHistoryLimit = 30
    private var refreshTimer: Timer?
    private var refreshInProgress = false
    private var noticeDismissWorkItem: DispatchWorkItem?
    private var isFanPageVisible = false
    private var coolModeRequestInProgress = false
    private var hasAppliedCoolModeTargets = false
    private var coolModeAlgorithm = CoolModeAlgorithm()

    init(monitor: SystemMonitor, monitoringLogs: MonitoringLogRecorder) {
        self.monitor = monitor
        self.monitoringLogs = monitoringLogs
        self.coolModePolicy = CoolModePreferences.currentPolicy
    }

    func start() {
        isFanPageVisible = true
        refresh()
        updateRefreshTimer()
    }

    func stop() {
        isFanPageVisible = false
        updateRefreshTimer()
    }

    func startBackgroundLoggingIfNeeded() {
        updateRefreshTimer()
    }

    func setMonitoringLogPersistenceEnabled(_: Bool) {
        updateRefreshTimer()
    }

    func refresh(showLoading: Bool = true) {
        guard !refreshInProgress, busyFanIndex == nil else { return }
        refreshInProgress = true
        if showLoading, fans.isEmpty {
            isLoading = true
        }

        queue.async { [weak self] in
            do {
                let snapshot = try SMCController().snapshot()
                let helperState = PrivilegedFanControl.authorizationState()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hardwareModel = snapshot.hardwareModel
                    self.fans = snapshot.fans
                    self.temperatures = snapshot.temperatures
                    self.updateTemperatureHistories(with: snapshot.temperatures)
                    self.helperAuthorizationState = helperState
                    self.availabilityMessage =
                        snapshot.fans.isEmpty && snapshot.temperatures.isEmpty
                        ? "这台 Mac 没有向系统报告可读取的风扇或温度传感器。"
                        : ""
                    self.isLoading = false
                    self.refreshInProgress = false
                    self.recordFanSnapshot()
                    self.evaluateCoolModeIfNeeded()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hardwareModel = SMCController.hardwareModel()
                    self.fans = []
                    self.temperatures = []
                    self.isLoading = false
                    self.refreshInProgress = false
                    self.availabilityMessage = self.friendlyMessage(for: error)
                    if self.coolModeState.isEnabled || self.hasAppliedCoolModeTargets {
                        self.failCoolMode("无法读取风扇或温度信息，清凉模式已停止：\(self.friendlyMessage(for: error))")
                    }
                }
            }
        }
    }

    private func updateRefreshTimer() {
        let shouldRefresh =
            isFanPageVisible
            || coolModeState.keepsControlLoopAlive
            || monitoringLogs.isPersistenceEnabled
        if shouldRefresh, refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.refresh(showLoading: false)
            }
        } else if !shouldRefresh {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    func apply(rpm: Double, to fan: FanReading) {
        guard busyFanIndex == nil, !coolModeRequestInProgress else { return }
        guard helperAuthorizationState.isEnabled else {
            errorMessage = "请先完成一次性授权，再调整风扇转速。"
            return
        }
        let shouldStopCoolMode = coolModeState.isEnabled || hasAppliedCoolModeTargets
        busyFanIndex = fan.index
        dismissNotice()
        if shouldStopCoolMode {
            coolModeState = .stopping
            updateRefreshTimer()
        }

        let safeRPM = min(max(rpm, fan.minimumRPM), fan.maximumRPM).rounded()
        queue.async { [weak self] in
            do {
                if shouldStopCoolMode {
                    try PrivilegedFanControl.stopCoolMode()
                }
                try PrivilegedFanControl.setFanRPM(
                    index: fan.index,
                    rpm: safeRPM
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyFanIndex = nil
                    if shouldStopCoolMode {
                        self.completeCoolModeStop(showNotice: false)
                    }
                    self.showNotice("风扇 \(fan.index + 1) 已设为 \(Int(safeRPM)) RPM")
                    self.refresh(showLoading: false)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyFanIndex = nil
                    if shouldStopCoolMode {
                        self.coolModeState = .failed(self.friendlyMessage(for: error))
                        self.updateRefreshTimer()
                    }
                    self.errorMessage = self.friendlyMessage(for: error)
                    self.refresh(showLoading: false)
                }
            }
        }
    }

    func restoreAutomatic(_ fan: FanReading) {
        guard busyFanIndex == nil, !coolModeRequestInProgress else { return }
        guard helperAuthorizationState.isEnabled else {
            errorMessage = "请先完成一次性授权，再恢复自动控制。"
            return
        }
        let shouldStopCoolMode = coolModeState.isEnabled || hasAppliedCoolModeTargets
        busyFanIndex = fan.index
        dismissNotice()
        if shouldStopCoolMode {
            coolModeState = .stopping
            updateRefreshTimer()
        }

        queue.async { [weak self] in
            do {
                if shouldStopCoolMode {
                    try PrivilegedFanControl.stopCoolMode()
                }
                try PrivilegedFanControl.setFanAutomatic(index: fan.index)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyFanIndex = nil
                    if shouldStopCoolMode {
                        self.completeCoolModeStop(showNotice: false)
                    }
                    self.showNotice("风扇 \(fan.index + 1) 已恢复由 macOS 自动控制")
                    self.refresh(showLoading: false)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyFanIndex = nil
                    if shouldStopCoolMode {
                        self.coolModeState = .failed(self.friendlyMessage(for: error))
                        self.updateRefreshTimer()
                    }
                    self.errorMessage = self.friendlyMessage(for: error)
                    self.refresh(showLoading: false)
                }
            }
        }
    }

    func enablePersistentHelper() {
        guard !isRegisteringHelper else { return }
        isRegisteringHelper = true
        errorMessage = nil

        queue.async { [weak self] in
            do {
                try PrivilegedFanControl.register()
                let state = PrivilegedFanControl.authorizationState()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.helperAuthorizationState = state
                    self.isRegisteringHelper = false
                    if state == .requiresApproval {
                        self.showNotice("请在“登录项与扩展”中允许 Mac-TaskManager 后台运行。")
                    } else if state == .enabled {
                        self.showNotice("一次性授权已完成，后续调整不再重复输入密码。")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.helperAuthorizationState = PrivilegedFanControl.authorizationState()
                    self.isRegisteringHelper = false
                    self.errorMessage = self.friendlyMessage(for: error)
                }
            }
        }
    }

    func openHelperSystemSettings() {
        PrivilegedFanControl.openSystemSettings()
    }

    func setCoolModePolicy(_ policy: CoolModePolicy) {
        guard coolModePolicy != policy else { return }
        coolModePolicy = policy
        coolModeAlgorithm.reset()
        recordCoolModeDecision(
            event: "policyChanged",
            message: "清凉模式策略已切换为 \(policy.rawValue)"
        )

        if coolModeState.isEnabled {
            refresh(showLoading: false)
        }
    }

    func toggleCoolMode() {
        if coolModeState.isEnabled || hasAppliedCoolModeTargets {
            disableCoolMode(showNotice: true)
        } else {
            enableCoolMode()
        }
    }

    func shutdown() {
        guard hasAppliedCoolModeTargets else { return }
        recordCoolModeDecision(event: "shutdown")
        try? PrivilegedFanControl.stopCoolMode()
        hasAppliedCoolModeTargets = false
        coolModeState = .off
        coolModeTargets = [:]
        coolModeAssessment = nil
    }

    private func enableCoolMode() {
        guard !coolModeRequestInProgress else { return }

        let helperState = PrivilegedFanControl.authorizationState()
        helperAuthorizationState = helperState
        guard helperState.isEnabled else {
            errorMessage = "请先完成一次性授权，再启用清凉模式。"
            recordCoolModeDecision(
                event: "startRejected",
                message: "风扇控制服务尚未完成授权"
            )
            return
        }

        coolModeAlgorithm.reset()
        coolModeAssessment = nil
        coolModeTargets = [:]
        coolModeState = .starting
        recordCoolModeDecision(event: "startRequested")
        updateRefreshTimer()
        refresh(showLoading: false)
    }

    private func disableCoolMode(showNotice shouldAnnounce: Bool) {
        guard coolModeState != .off || hasAppliedCoolModeTargets else { return }
        coolModeState = .stopping
        coolModeRequestInProgress = true
        recordCoolModeDecision(event: "stopRequested")
        updateRefreshTimer()

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try PrivilegedFanControl.stopCoolMode()
                DispatchQueue.main.async {
                    self.completeCoolModeStop(showNotice: shouldAnnounce)
                }
            } catch {
                DispatchQueue.main.async {
                    self.coolModeState = .failed(self.friendlyMessage(for: error))
                    self.errorMessage = "清凉模式未能立即恢复自动散热：\(self.friendlyMessage(for: error))"
                    self.recordCoolModeDecision(
                        event: "stopFailed",
                        message: self.friendlyMessage(for: error)
                    )
                    self.coolModeRequestInProgress = false
                    self.updateRefreshTimer()
                }
            }
        }
    }

    private func completeCoolModeStop(showNotice shouldAnnounce: Bool) {
        hasAppliedCoolModeTargets = false
        coolModeRequestInProgress = false
        coolModeState = .off
        coolModeTargets = [:]
        coolModeAssessment = nil
        coolModeAlgorithm.reset()
        recordCoolModeDecision(event: "stopped")
        updateRefreshTimer()
        if shouldAnnounce {
            showNotice("清凉模式已关闭，已恢复 macOS 自动散热")
        }
    }

    private func evaluateCoolModeIfNeeded() {
        guard coolModeState == .starting || coolModeState == .active,
              !coolModeRequestInProgress else {
            return
        }
        guard helperAuthorizationState.isEnabled else {
            failCoolMode("清凉模式需要风扇控制服务授权。")
            return
        }
        guard !fans.isEmpty else {
            failCoolMode("未检测到可控制的风扇，无法启用清凉模式。")
            return
        }

        let input = coolModeInput()
        guard input.hasTemperatureFeedback else {
            failCoolMode("未检测到可用温度传感器，清凉模式已保持 macOS 自动散热。")
            return
        }

        let assessment = coolModeAlgorithm.assess(input, policy: coolModePolicy)
        let targets = Dictionary(uniqueKeysWithValues: fans.map { fan in
            (
                fan.index,
                CoolModeFanTargetMapper.targetRPM(
                    minimumRPM: fan.minimumRPM,
                    maximumRPM: fan.maximumRPM,
                    coolingDemand: assessment.coolingDemand
                )
            )
        })
        guard !targets.isEmpty else {
            failCoolMode("清凉模式没有生成有效的风扇目标转速。")
            return
        }

        recordCoolModeDecision(
            event: "decisionRequested",
            input: input,
            assessment: assessment,
            targets: targets
        )

        coolModeRequestInProgress = true
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try PrivilegedFanControl.updateCoolModeTargets(targets)
                DispatchQueue.main.async {
                    self.coolModeRequestInProgress = false
                    self.hasAppliedCoolModeTargets = true
                    guard self.coolModeState == .starting || self.coolModeState == .active else {
                        return
                    }
                    self.coolModeState = .active
                    self.coolModeAssessment = assessment
                    self.coolModeTargets = targets
                    self.recordCoolModeDecision(
                        event: "decisionApplied",
                        input: input,
                        assessment: assessment,
                        targets: targets
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.coolModeRequestInProgress = false
                    self.recordCoolModeDecision(
                        event: "decisionFailed",
                        input: input,
                        assessment: assessment,
                        targets: targets,
                        message: self.friendlyMessage(for: error)
                    )
                    self.failCoolMode("清凉模式未能更新风扇：\(self.friendlyMessage(for: error))")
                }
            }
        }
    }

    private func failCoolMode(_ message: String) {
        let shouldStop = hasAppliedCoolModeTargets
        coolModeState = .failed(message)
        coolModeRequestInProgress = false
        errorMessage = message
        recordCoolModeDecision(event: "failed", message: message)
        updateRefreshTimer()

        if shouldStop {
            queue.async { [weak self] in
                try? PrivilegedFanControl.stopCoolMode()
                DispatchQueue.main.async {
                    self?.hasAppliedCoolModeTargets = false
                    self?.coolModeTargets = [:]
                    self?.coolModeAssessment = nil
                }
            }
        }
    }

    private func coolModeInput() -> CoolModeInput {
        CoolModeInput(
            cpuUsage: monitor.totalCPU,
            gpuUsage: monitor.totalGPU,
            memoryUsage: memoryUsagePercent,
            diskBytesPerSecond: monitor.totalDiskBytesPerSecond,
            cpuTemperature: maximumTemperature(in: .cpu),
            gpuTemperature: maximumTemperature(in: .gpu),
            systemTemperature: maximumTemperature(in: .system)
        )
    }

    private var memoryUsagePercent: Double {
        guard monitor.totalMemory > 0 else { return 0 }
        return Double(monitor.usedMemory) / Double(monitor.totalMemory) * 100
    }

    private func maximumTemperature(in group: TemperatureSensorGroup) -> Double? {
        temperatures
            .filter { $0.group == group && $0.celsius > 0 }
            .map(\.celsius)
            .max()
    }

    func captureSnapshotForLogExport(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: completion)
                return
            }

            do {
                let snapshot = try SMCController().snapshot()
                let helperState = PrivilegedFanControl.authorizationState()
                DispatchQueue.main.async {
                    self.hardwareModel = snapshot.hardwareModel
                    self.fans = snapshot.fans
                    self.temperatures = snapshot.temperatures
                    self.updateTemperatureHistories(with: snapshot.temperatures)
                    self.helperAuthorizationState = helperState
                    self.recordFanSnapshot()
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    self.recordFanSnapshot()
                    completion()
                }
            }
        }
    }

    private func recordFanSnapshot() {
        monitoringLogs.recordFanSnapshot(
            MonitoringFanLogSnapshot(
                timestamp: Date(),
                hardwareModel: hardwareModel,
                helperAuthorizationState: monitoringLogAuthorizationState,
                coolModeState: monitoringLogCoolModeState,
                coolModePolicy: coolModePolicy.rawValue,
                coolModeTargets: Dictionary(
                    uniqueKeysWithValues: coolModeTargets.map { (String($0.key), $0.value) }
                ),
                fans: fans.map(\.monitoringLogRecord),
                temperatures: temperatures.map(\.monitoringLogRecord)
            )
        )
    }

    private func recordCoolModeDecision(
        event: String,
        input: CoolModeInput? = nil,
        assessment: CoolModeAssessment? = nil,
        targets: [Int: Double]? = nil,
        message: String? = nil
    ) {
        let selectedTargets = targets ?? coolModeTargets
        monitoringLogs.recordCoolModeDecision(
            MonitoringCoolModeDecision(
                timestamp: Date(),
                event: event,
                state: monitoringLogCoolModeState,
                policy: coolModePolicy.rawValue,
                helperAuthorizationState: monitoringLogAuthorizationState,
                input: input?.monitoringLogRecord,
                assessment: assessment?.monitoringLogRecord,
                targetRPMs: Dictionary(
                    uniqueKeysWithValues: selectedTargets.map { (String($0.key), $0.value) }
                ),
                fans: fans.map(\.monitoringLogRecord),
                message: message
            )
        )
    }

    private var monitoringLogAuthorizationState: String {
        switch helperAuthorizationState {
        case .checking: return "checking"
        case .notRegistered: return "notRegistered"
        case .needsUpdate: return "needsUpdate"
        case .requiresApproval: return "requiresApproval"
        case .enabled: return "enabled"
        case .unavailable(let message): return "unavailable: \(message)"
        }
    }

    private var monitoringLogCoolModeState: String {
        switch coolModeState {
        case .off: return "off"
        case .starting: return "starting"
        case .active: return "active"
        case .stopping: return "stopping"
        case .failed(let message): return "failed: \(message)"
        }
    }

    func showNotice(_ message: String) {
        noticeDismissWorkItem?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            noticeMessage = message
        }

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.noticeMessage = nil
                }
            }
        }
        noticeDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissWorkItem)
    }

    private func dismissNotice() {
        noticeDismissWorkItem?.cancel()
        noticeDismissWorkItem = nil
        withAnimation(.easeOut(duration: 0.16)) {
            noticeMessage = nil
        }
    }

    private func updateTemperatureHistories(with readings: [TemperatureReading]) {
        let activeKeys = Set(readings.map(\.key))
        temperatureHistories = temperatureHistories.filter { activeKeys.contains($0.key) }

        for reading in readings {
            var history = temperatureHistories[reading.key]
                ?? Array(repeating: reading.celsius, count: temperatureHistoryLimit)
            history.append(reading.celsius)
            temperatureHistories[reading.key] = Array(history.suffix(temperatureHistoryLimit))
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
            return "已取消管理员授权，风扇设置没有改变。"
        }
        if message.contains("FNum") || message.contains("AppleSMC") {
            return "这台 Mac 没有可读取的硬件风扇，或当前系统不允许访问 AppleSMC。"
        }
        return message
    }

    deinit {
        refreshTimer?.invalidate()
        noticeDismissWorkItem?.cancel()
    }
}

private enum PrivilegedFanControl {
    enum ControlError: LocalizedError {
        case helperNotEnabled
        case connectionFailed(String)
        case commandFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .helperNotEnabled:
                return "风扇控制服务尚未完成一次性授权。"
            case .connectionFailed(let message):
                return "无法连接风扇控制服务：\(message)"
            case .commandFailed(let message):
                return message.isEmpty ? "风扇控制操作失败。" : message
            case .timeout:
                return "风扇控制服务没有及时响应。"
            }
        }
    }

    static func authorizationState() -> FanHelperAuthorizationState {
        switch FanHelperRegistration.service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return FanHelperRegistration.isCurrentBuildRegistered
                ? .enabled
                : .needsUpdate
        case .requiresApproval:
            return FanHelperRegistration.isCurrentBuildRegistered
                ? .requiresApproval
                : .needsUpdate
        case .notFound:
            return .notRegistered
        @unknown default:
            return .unavailable("无法识别风扇控制服务状态。")
        }
    }

    static func register() throws {
        try FanHelperRegistration.registerOrRefresh()
    }

    static func openSystemSettings() {
        FanHelperRegistration.openSystemSettings()
    }

    static func setFanRPM(index: Int, rpm: Double) throws {
        try perform { proxy, completion in
            proxy.setFanRPM(index: index, rpm: rpm, withReply: completion)
        }
    }

    static func setFanAutomatic(index: Int) throws {
        try perform { proxy, completion in
            proxy.setFanAutomatic(index: index, withReply: completion)
        }
    }

    static func updateCoolModeTargets(_ targets: [Int: Double]) throws {
        let sortedTargets = targets.sorted { $0.key < $1.key }
        try perform { proxy, completion in
            proxy.updateCoolModeTargets(
                indexes: sortedTargets.map { NSNumber(value: $0.key) },
                rpms: sortedTargets.map { NSNumber(value: $0.value) },
                withReply: completion
            )
        }
    }

    static func stopCoolMode() throws {
        try perform { proxy, completion in
            proxy.stopCoolMode(withReply: completion)
        }
    }

    private static func perform(
        _ operation: (
            FanControlXPCProtocol,
            @escaping (Bool, String?) -> Void
        ) -> Void
    ) throws {
        guard authorizationState().isEnabled else {
            throw ControlError.helperNotEnabled
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var response: Result<Void, Error>?

        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard response == nil else { return }
            response = result
            semaphore.signal()
        }

        let connection = NSXPCConnection(
            machServiceName: FanControlXPC.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: FanControlXPCProtocol.self
        )
        connection.interruptionHandler = {
            finish(.failure(ControlError.connectionFailed("连接被中断。")))
        }
        connection.invalidationHandler = {
            finish(.failure(ControlError.connectionFailed("连接已失效。")))
        }
        connection.resume()
        defer {
            connection.interruptionHandler = nil
            connection.invalidationHandler = nil
            connection.invalidate()
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.failure(ControlError.connectionFailed(error.localizedDescription)))
        }) as? FanControlXPCProtocol else {
            throw ControlError.connectionFailed("无法创建服务代理。")
        }

        operation(proxy) { success, message in
            if success {
                finish(.success(()))
            } else {
                finish(.failure(ControlError.commandFailed(message ?? "")))
            }
        }

        // The helper may spend up to 10 seconds waiting for macOS to release
        // manual fan control, so leave enough time for XPC startup and the
        // final SMC write to complete as well.
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            throw ControlError.timeout
        }
        try response?.get()
    }
}

struct FanControlPage: View {
    @ObservedObject var model: FanControlModel

    var body: some View {
        VStack(spacing: 0) {
            pageHeader

            ZStack(alignment: .top) {
                Group {
                    if model.isLoading {
                        ProgressView("正在读取风扇状态…")
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.fans.isEmpty && model.temperatures.isEmpty {
                        unsupportedView
                    } else {
                        fanDashboard
                    }
                }

            }
        }
        .background(TaskManagerStyle.surface)
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .alert(
            "风扇控制",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { presented in
                    if !presented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Text("风扇控制")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(TaskManagerStyle.text)

            if model.busyFanIndex != nil || model.isRegisteringHelper {
                ProgressView()
                    .controlSize(.small)
                Text(model.isRegisteringHelper ? "正在启用服务…" : "正在应用设置…")
                    .font(.system(size: 13))
                    .foregroundColor(TaskManagerStyle.muted)
            }

            Spacer()

            Button {
                model.toggleCoolMode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 16, weight: .semibold))
                    Text(model.coolModeState.buttonTitle)
                        .font(.system(size: 14))
                }
                .foregroundColor(
                    model.coolModeState.isButtonActive
                        ? .white
                        : TaskManagerStyle.text
                )
                .frame(height: 36)
                .padding(.horizontal, 12)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            model.coolModeState.isButtonActive
                                ? Color(red: 0.0, green: 0.40, blue: 0.75)
                                : .clear
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(
                model.busyFanIndex != nil
                    || model.isRegisteringHelper
                    || model.coolModeState.isTransitioning
            )

            Button {
                model.refresh()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                    Text("刷新")
                        .font(.system(size: 14))
                }
                .foregroundColor(TaskManagerStyle.text)
                .frame(height: 36)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .disabled(model.busyFanIndex != nil)
        }
        .padding(.horizontal, 20)
        .frame(height: 63)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TaskManagerStyle.grid)
                .frame(height: 1)
        }
    }

    private var fanDashboard: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !model.helperAuthorizationState.isEnabled {
                    FanHelperSetupBanner(
                        state: model.helperAuthorizationState,
                        isRegistering: model.isRegisteringHelper,
                        onEnable: model.enablePersistentHelper,
                        onOpenSettings: model.openHelperSystemSettings
                    )
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(model.fans) { fan in
                        FanControlCard(
                            fan: fan,
                            isBusy: model.busyFanIndex != nil,
                            isControlEnabled: model.helperAuthorizationState.isEnabled,
                            coolModeState: model.coolModeState,
                            coolModeAssessment: model.coolModeAssessment,
                            coolModeTargetRPM: model.coolModeTargets[fan.index],
                            onApply: { rpm in
                                model.apply(rpm: rpm, to: fan)
                            },
                            onAutomatic: {
                                model.restoreAutomatic(fan)
                            }
                        )
                    }
                }

                TemperatureSensorCharts(
                    readings: model.temperatures,
                    histories: model.temperatureHistories
                )
            }
            .padding(20)
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(TaskManagerStyle.chrome)
                    .frame(width: 76, height: 76)
                Image(systemName: "fanblades")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(TaskManagerStyle.muted)
            }

            Text("未检测到可控制的风扇")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(TaskManagerStyle.text)

            Text(model.availabilityMessage)
                .font(.system(size: 13))
                .foregroundColor(TaskManagerStyle.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)

            Button("重新检测") {
                model.refresh()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct CoolModeFanMask: View {
    let state: CoolModeState
    let assessment: CoolModeAssessment?
    let targetRPM: Double?

    private var title: String {
        switch state {
        case .starting, .active:
            return "清凉模式运行中"
        case .stopping, .off, .failed:
            return "清凉模式"
        }
    }

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "snowflake")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(TaskManagerStyle.muted)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(TaskManagerStyle.text)

            if (state == .starting || state == .active), let assessment {
                Text("预测压力 \(assessment.heatLevel.title) · \(assessment.dominantFactor)")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                if let targetRPM {
                    Text("目标 \(Int(targetRPM.rounded())) RPM")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TaskManagerStyle.text)
                }
            } else {
                Text("风扇控制暂由清凉模式接管")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskManagerStyle.coolModeMask)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(TaskManagerStyle.muted.opacity(0.34), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { }
    }
}

struct FanControlToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(red: 0.06, green: 0.56, blue: 0.31))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(TaskManagerStyle.text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 46)
        .frame(maxWidth: 390, alignment: .leading)
        .background(.regularMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(red: 0.69, green: 0.86, blue: 0.76), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .allowsHitTesting(false)
    }
}

private struct FanControlCard: View {
    let fan: FanReading
    let isBusy: Bool
    let isControlEnabled: Bool
    let coolModeState: CoolModeState
    let coolModeAssessment: CoolModeAssessment?
    let coolModeTargetRPM: Double?
    let onApply: (Double) -> Void
    let onAutomatic: () -> Void

    @StateObject private var state: FanControlCardState

    init(
        fan: FanReading,
        isBusy: Bool,
        isControlEnabled: Bool,
        coolModeState: CoolModeState,
        coolModeAssessment: CoolModeAssessment?,
        coolModeTargetRPM: Double?,
        onApply: @escaping (Double) -> Void,
        onAutomatic: @escaping () -> Void
    ) {
        self.fan = fan
        self.isBusy = isBusy
        self.isControlEnabled = isControlEnabled
        self.coolModeState = coolModeState
        self.coolModeAssessment = coolModeAssessment
        self.coolModeTargetRPM = coolModeTargetRPM
        self.onApply = onApply
        self.onAutomatic = onAutomatic
        let initial = fan.targetRPM >= fan.minimumRPM ? fan.targetRPM : max(fan.actualRPM, fan.minimumRPM)
        _state = StateObject(
            wrappedValue: FanControlCardState(
                requestedRPM: min(max(initial, fan.minimumRPM), fan.maximumRPM)
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "fanblades")
                        .font(.system(size: 21, weight: .light))
                        .foregroundColor(Color(red: 0.0, green: 0.40, blue: 0.75))
                    Text("风扇 \(fan.index + 1)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(TaskManagerStyle.text)
                }
                Spacer()
                Text(fan.isManual ? "手动控制" : "系统自动")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(fan.isManual ? Color(red: 0.0, green: 0.36, blue: 0.70) : Color(red: 0.07, green: 0.48, blue: 0.28))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        fan.isManual
                            ? TaskManagerStyle.manualBadge
                            : TaskManagerStyle.automaticBadge
                    )
                    .clipShape(Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(fan.actualRPM.rounded()))")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(TaskManagerStyle.text)
                Text("RPM")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(TaskManagerStyle.muted)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("目标 \(fan.targetRPM > 0 ? "\(Int(fan.targetRPM.rounded())) RPM" : "由系统决定")")
                    Text("范围 \(Int(fan.minimumRPM.rounded()))–\(Int(fan.maximumRPM.rounded())) RPM")
                }
                .font(.system(size: 11))
                .foregroundColor(TaskManagerStyle.muted)
            }

            VStack(spacing: 8) {
                HStack {
                    Text("设置转速")
                    Spacer()
                    Text("\(Int(state.requestedRPM.rounded())) RPM")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 12))
                .foregroundColor(TaskManagerStyle.text)

                Slider(
                    value: $state.requestedRPM,
                    in: fan.minimumRPM...max(fan.minimumRPM, fan.maximumRPM),
                    step: 50
                )
                .tint(Color(red: 0.0, green: 0.40, blue: 0.75))
                .disabled(isBusy || !isControlEnabled || coolModeState.isEnabled)

                HStack {
                    Text("\(Int(fan.minimumRPM.rounded()))")
                    Spacer()
                    Text("\(Int(fan.maximumRPM.rounded()))")
                }
                .font(.system(size: 10))
                .foregroundColor(TaskManagerStyle.muted)
            }

            HStack(spacing: 10) {
                Button("恢复自动") {
                    onAutomatic()
                }
                .buttonStyle(FanSecondaryButtonStyle())
                .disabled(isBusy || !isControlEnabled || !fan.isManual || coolModeState.isEnabled)

                Button("应用此转速") {
                    onApply(state.requestedRPM)
                }
                .buttonStyle(FanPrimaryButtonStyle())
                .disabled(isBusy || !isControlEnabled || coolModeState.isEnabled)
            }
        }
        .padding(18)
        .background(TaskManagerStyle.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(TaskManagerStyle.grid, lineWidth: 1)
        }
        .overlay {
            if coolModeState.isButtonActive {
                CoolModeFanMask(
                    state: coolModeState,
                    assessment: coolModeAssessment,
                    targetRPM: coolModeTargetRPM
                )
            }
        }
        .onChange(of: fan.targetRPM) { value in
            guard value >= fan.minimumRPM, value <= fan.maximumRPM else { return }
            state.requestedRPM = value
        }
    }
}

private struct FanHelperSetupBanner: View {
    let state: FanHelperAuthorizationState
    let isRegistering: Bool
    let onEnable: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(
                systemName:
                    state == .requiresApproval
                    ? "gearshape.2"
                    : state == .needsUpdate
                        ? "arrow.triangle.2.circlepath"
                        : "lock.shield"
            )
                .font(.system(size: 20))
                .foregroundColor(Color(red: 0.0, green: 0.40, blue: 0.75))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(TaskManagerStyle.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if state == .checking || isRegistering {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 104)
            } else if state == .requiresApproval {
                Button("打开系统设置", action: onOpenSettings)
                    .buttonStyle(FanPrimaryButtonStyle())
                    .frame(width: 130)
            } else {
                Button(state == .needsUpdate ? "更新服务" : "一次性启用", action: onEnable)
                    .buttonStyle(FanPrimaryButtonStyle())
                    .frame(width: 130)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(TaskManagerStyle.helperBanner)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TaskManagerStyle.helperBannerBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var title: String {
        switch state {
        case .checking:
            return "正在检查风扇控制授权"
        case .notRegistered:
            return "启用免重复密码的风扇控制"
        case .needsUpdate:
            return "应用已更新，需要刷新风扇控制服务"
        case .requiresApproval:
            return "还需要在系统设置中允许后台运行"
        case .enabled:
            return "风扇控制服务已启用"
        case .unavailable:
            return "风扇控制服务不可用"
        }
    }

    private var detail: String {
        switch state {
        case .checking:
            return "正在读取 macOS 后台服务状态。"
        case .notRegistered:
            return "首次启用需要管理员批准；之后调整转速不再反复输入密码。"
        case .needsUpdate:
            return "更新后的 helper 必须重新注册，才能使用当前版本的签名和路径。"
        case .requiresApproval:
            return "在“通用 → 登录项与扩展”中允许 Mac-TaskManager，然后返回这里。"
        case .enabled:
            return "后续调整将通过受保护的系统服务完成。"
        case .unavailable(let message):
            return message
        }
    }
}

private final class FanControlCardState: ObservableObject {
    @Published var requestedRPM: Double

    init(requestedRPM: Double) {
        self.requestedRPM = requestedRPM
    }
}

struct FanPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                configuration.isPressed
                    ? Color(red: 0.0, green: 0.31, blue: 0.60)
                    : Color(red: 0.0, green: 0.40, blue: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct FanSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(TaskManagerStyle.text)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(configuration.isPressed ? TaskManagerStyle.pressedOverlay : TaskManagerStyle.elevatedSurface)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(TaskManagerStyle.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct TemperatureSensorCharts: View {
    let readings: [TemperatureReading]
    let histories: [String: [Double]]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 18))
                    .foregroundColor(PerformanceResource.cpu.color)
                Text("温度传感器")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(TaskManagerStyle.text)
                Spacer()
            }

            if readings.isEmpty {
                Text("未检测到可读取的温度传感器")
                    .font(.system(size: 13))
                    .foregroundColor(TaskManagerStyle.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 12),
                        count: 4
                    ),
                    spacing: 14
                ) {
                    ForEach(readings) { reading in
                        TemperatureSensorChart(
                            reading: reading,
                            history: histories[reading.key] ?? [reading.celsius]
                        )
                    }
                }
            }
        }
    }
}

private struct TemperatureSensorChart: View {
    let reading: TemperatureReading
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(reading.name)
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: "%.1f °C", reading.celsius))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(TaskManagerStyle.muted)
                    .lineLimit(1)
            }

            PerformanceGraph(
                values: history,
                maxValue: 100,
                color: PerformanceResource.cpu.color,
                fillOpacity: 0.18,
                lineWidth: 0.8
            )
            .frame(height: 82)
        }
    }
}
