import SwiftUI
import AppKit
import Foundation
import Darwin

// MARK: - Models
enum ProcessStatus {
    case none
    case efficiency
    case suspended
}

struct AppProcess: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let parentPID: Int32
    let name: String
    let cpuUsage: Double
    let gpuUsage: Double
    let memoryUsage: UInt64
    let diskBytesPerSecond: Double
    let networkBytesPerSecond: Double
    let user: String
    let icon: NSImage?
    let isApp: Bool
    let status: ProcessStatus
}

struct CPUCore: Identifiable {
    let id: Int
    let usage: Double
}

struct PortEntry: Identifiable {
    let id = UUID()
    let port: String
    let process: String
    let pid: String
    let proto: String
}

struct HardwareInfo {
    var cpuName = "CPU"
    var cpuDisplayName = "CPU"
    var cpuCoreSummary = "未知核心"
    var cpuBaseSpeed = "不可用"
    var cpuL1Cache = "不可用"
    var cpuL2Cache = "不可用"
    var cpuL3Cache = "不可用"
    var physicalCPUCount = 0
    var logicalCPUCount = 0
    var memoryCapacity = "0 GB"
    var memoryType = "未知"
    var memoryManufacturer = "未知"
    var memoryDisplayName = "内存"

    var diskTitle = "磁盘 0"
    var diskName = "存储设备"
    var diskDisplayName = "存储设备"
    var diskBSDName = ""
    var diskCapacity = "未知"
    var diskFileSystem = "未知"
    var diskMediumType = "未知"
    var diskProtocol = "未知"
    var diskInternal = "未知"

    var wifiInterface = "Wi-Fi"
    var wifiCardName = "Wi-Fi"
    var wifiDisplayName = "Wi-Fi"
    var wifiSSID = "未连接"
    var wifiConnectionType = "未知"
    var wifiIPv4 = "无"
    var wifiStatus = "未知"

    var gpuName = "GPU"
    var gpuDisplayName = "GPU"
    var gpuCoreSummary = "未知核心"
    var gpuType = "GPU"
    var gpuBus = "未知"
    var gpuVendor = "未知"
    var gpuMetalSupport = "未知"
}

// MARK: - System Monitor
class SystemMonitor: ObservableObject {
    @Published var processes: [AppProcess] = []
    @Published var cpuCores: [CPUCore] = []
    @Published var totalCPU: Double = 0.0
    @Published var totalGPU: Double = 0.0
    @Published var totalMemory: UInt64 = 0
    @Published var usedMemory: UInt64 = 0
    @Published var ports: [PortEntry] = []
    @Published var hardwareInfo = HardwareInfo()
    @Published var totalDiskBytesPerSecond: Double = 0
    @Published var diskReadBytesPerSecond: Double = 0
    @Published var diskWriteBytesPerSecond: Double = 0
    @Published var totalNetworkBytesPerSecond: Double = 0
    @Published var networkReceiveBytesPerSecond: Double = 0
    @Published var networkSendBytesPerSecond: Double = 0
    @Published var cpuCoreHistories: [[Double]] = []
    @Published var memoryHistory: [Double] = []
    @Published var diskActivityHistory: [Double] = []
    @Published var diskTransferHistory: [Double] = []
    @Published var wifiThroughputHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    private(set) var processVersion = 0

    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "MacSystemMonitor.refresh", qos: .background)
    private let networkQueue = DispatchQueue(label: "MacSystemMonitor.network", qos: .utility)
    private let networkLock = NSLock()
    private var previousCoreInfo: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var previousDiskTotals: [Int32: (read: UInt64, write: UInt64)] = [:]
    private var previousGPUTotals: [Int32: UInt64] = [:]
    private var previousNetworkTotals: [Int32: (received: UInt64, sent: UInt64)] = [:]
    private var networkRates: [Int32: Double] = [:]
    private var isNetworkSampling = false
    private var previousProcessSampleTime: Date?
    private var previousGPUSampleTime: Date?
    private var previousNetworkSampleTime: Date?
    private var cachedTotalGPU: Double = 0
    private var appIconCache: [Int32: NSImage] = [:]
    private let fallbackProcessIcon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
    private let performanceHistoryLimit = 30

    init() {
        startMonitoring()
        loadHardwareInfo()
    }

    func startMonitoring() {
        updateData()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateData()
        }
    }

    func updateData() {
        refreshQueue.async {
            self.updateProcesses()
            self.updateCPUCores()
            self.updateMemory()
            self.updatePorts()
            self.scheduleNetworkRateUpdate()
        }
    }

    private func loadHardwareInfo() {
        refreshQueue.async {
            let info = self.collectHardwareInfo()
            DispatchQueue.main.async {
                self.hardwareInfo = info
            }
        }
    }

    private struct StorageHardware {
        var volumeName = ""
        var mountPoint = ""
        var capacity = ""
        var fileSystem = ""
        var bsdName = ""
        var deviceName = ""
        var mediumType = ""
        var protocolName = ""
        var internalValue = ""
    }

    private func collectHardwareInfo() -> HardwareInfo {
        var info = HardwareInfo()

        let cpuBrand = sysctlText("machdep.cpu.brand_string")
        let chipName = profilerValue(named: "Chip", in: commandOutput(
            executablePath: "/usr/sbin/system_profiler",
            arguments: ["SPHardwareDataType", "-detailLevel", "mini"],
            timeout: 3.0
        ) ?? "")
        info.cpuName = firstNonEmpty(cpuBrand, chipName, sysctlText("hw.model"), fallback: "CPU")
        info.physicalCPUCount = sysctlInt("hw.physicalcpu") ?? 0
        info.logicalCPUCount = sysctlInt("hw.logicalcpu") ?? 0
        if let maxFrequency = sysctlInt("hw.cpufrequency_max") ?? sysctlInt("hw.cpufrequency"), maxFrequency > 0 {
            info.cpuBaseSpeed = String(format: "%.2f GHz", Double(maxFrequency) / 1_000_000_000)
        }
        if let l1Instruction = sysctlInt("hw.l1icachesize"),
           let l1Data = sysctlInt("hw.l1dcachesize") {
            info.cpuL1Cache = formatMemory(UInt64(l1Instruction + l1Data))
        }
        if let l2Cache = sysctlInt("hw.l2cachesize"), l2Cache > 0 {
            info.cpuL2Cache = formatMemory(UInt64(l2Cache))
        }
        if let l3Cache = sysctlInt("hw.l3cachesize"), l3Cache > 0 {
            info.cpuL3Cache = formatMemory(UInt64(l3Cache))
        }
        if info.physicalCPUCount > 0 {
            info.cpuCoreSummary = "\(info.physicalCPUCount) 核"
        }
        if info.logicalCPUCount > 0, info.logicalCPUCount != info.physicalCPUCount {
            info.cpuCoreSummary += " / \(info.logicalCPUCount) 逻辑"
        }
        info.cpuDisplayName = joinedHardwareName([
            info.cpuName,
            info.physicalCPUCount > 0 ? "\(info.physicalCPUCount)-Core CPU" : nil
        ])
        info.memoryCapacity = formatMemory(Foundation.ProcessInfo.processInfo.physicalMemory)
        if let memoryOutput = commandOutput(
            executablePath: "/usr/sbin/system_profiler",
            arguments: ["SPMemoryDataType", "-detailLevel", "mini"],
            timeout: 3.0
        ) {
            info.memoryCapacity = firstNonEmpty(profilerValue(named: "Memory", in: memoryOutput), info.memoryCapacity, fallback: info.memoryCapacity)
            info.memoryType = firstNonEmpty(profilerValue(named: "Type", in: memoryOutput), fallback: "未知")
            info.memoryManufacturer = firstNonEmpty(profilerValue(named: "Manufacturer", in: memoryOutput), fallback: "未知")
        }
        info.memoryDisplayName = joinedHardwareName([
            info.memoryManufacturer == "未知" ? nil : info.memoryManufacturer,
            info.memoryType == "未知" ? nil : info.memoryType,
            info.memoryCapacity
        ])

        if let storageOutput = commandOutput(
            executablePath: "/usr/sbin/system_profiler",
            arguments: ["SPStorageDataType", "-detailLevel", "mini"],
            timeout: 4.0
        ), let disk = storageHardware(from: storageOutput) {
            info.diskBSDName = disk.bsdName
            info.diskTitle = disk.bsdName.isEmpty ? "磁盘 0" : "磁盘 0 (\(disk.bsdName))"
            info.diskName = firstNonEmpty(disk.deviceName, disk.volumeName, fallback: "存储设备")
            info.diskCapacity = firstNonEmpty(disk.capacity, fallback: "未知")
            info.diskFileSystem = firstNonEmpty(disk.fileSystem, fallback: "未知")
            info.diskMediumType = firstNonEmpty(disk.mediumType, fallback: "未知")
            info.diskProtocol = firstNonEmpty(disk.protocolName, fallback: "未知")
            info.diskInternal = firstNonEmpty(disk.internalValue, fallback: "未知")
        }
        if let nvmeOutput = commandOutput(
            executablePath: "/usr/sbin/system_profiler",
            arguments: ["SPNVMeDataType", "-detailLevel", "mini"],
            timeout: 3.0
        ) {
            info.diskName = firstNonEmpty(profilerValue(named: "Model", in: nvmeOutput), info.diskName, fallback: info.diskName)
            info.diskCapacity = firstNonEmpty(profilerValue(named: "Capacity", in: nvmeOutput)?.components(separatedBy: " (").first, info.diskCapacity, fallback: info.diskCapacity)
            if let nvmeBSDName = profilerValue(named: "BSD Name", in: nvmeOutput), !nvmeBSDName.isEmpty {
                info.diskBSDName = nvmeBSDName
                info.diskTitle = "磁盘 0 (\(nvmeBSDName))"
            }
        }
        info.diskInternal = localizedYesNo(info.diskInternal)
        info.diskDisplayName = joinedHardwareName([
            info.diskName,
            info.diskCapacity == "未知" ? nil : info.diskCapacity,
            info.diskProtocol == "未知" ? nil : info.diskProtocol,
            info.diskMediumType == "未知" ? nil : info.diskMediumType
        ])

        if let displayOutput = commandOutput(
            executablePath: "/usr/sbin/system_profiler",
            arguments: ["SPDisplaysDataType", "-detailLevel", "basic"],
            timeout: 3.0
        ) {
            info.gpuName = firstNonEmpty(profilerValue(named: "Chipset Model", in: displayOutput), gpuHeading(from: displayOutput), fallback: "GPU")
            if let coreCount = profilerValue(named: "Total Number of Cores", in: displayOutput) {
                info.gpuCoreSummary = "\(coreCount) 核"
            }
            info.gpuType = firstNonEmpty(profilerValue(named: "Type", in: displayOutput), fallback: "GPU")
            info.gpuBus = firstNonEmpty(profilerValue(named: "Bus", in: displayOutput), fallback: "未知")
            info.gpuVendor = firstNonEmpty(profilerValue(named: "Vendor", in: displayOutput), fallback: "未知")
            info.gpuMetalSupport = firstNonEmpty(profilerValue(named: "Metal Support", in: displayOutput), fallback: "未知")
        }
        info.gpuDisplayName = joinedHardwareName([
            info.gpuName,
            info.gpuCoreSummary == "未知核心" ? nil : info.gpuCoreSummary.replacingOccurrences(of: " 核", with: "-Core"),
            info.gpuType
        ])

        let wifiInterface = wifiInterfaceName()
        info.wifiInterface = firstNonEmpty(wifiInterface, fallback: "Wi-Fi")
        if let wifiOutput = commandOutput(
            executablePath: "/usr/sbin/system_profiler",
            arguments: ["SPAirPortDataType", "-detailLevel", "mini"],
            timeout: 4.0
        ) {
            let cardType = profilerValue(named: "Card Type", in: wifiOutput)
            info.wifiCardName = firstNonEmpty(cardType, fallback: info.wifiInterface)
            info.wifiConnectionType = firstNonEmpty(profilerValue(named: "Supported PHY Modes", in: wifiOutput), fallback: "未知")
            info.wifiStatus = localizedWiFiStatus(profilerValue(named: "Status", in: wifiOutput))
        }
        if let interface = wifiInterface {
            info.wifiSSID = currentSSID(interface: interface)
            info.wifiIPv4 = firstNonEmpty(commandOutput(
                executablePath: "/usr/sbin/ipconfig",
                arguments: ["getifaddr", interface],
                timeout: 0.8
            )?.trimmingCharacters(in: .whitespacesAndNewlines), fallback: "无")
        }
        info.wifiDisplayName = joinedHardwareName([
            info.wifiCardName,
            info.wifiInterface == "Wi-Fi" ? nil : "(\(info.wifiInterface))"
        ])

        return info
    }

    private func joinedHardwareName(_ parts: [String?], separator: String = " ") -> String {
        let values = parts
            .compactMap { $0.map(compactHardwareText) }
            .filter { !$0.isEmpty }
        return values.joined(separator: separator)
    }

    private func compactHardwareText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func firstNonEmpty(_ values: String?..., fallback: String) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallback
    }

    private func sysctlText(_ key: String) -> String? {
        commandOutput(executablePath: "/usr/sbin/sysctl", arguments: ["-n", key], timeout: 0.8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sysctlInt(_ key: String) -> Int? {
        guard let text = sysctlText(key), !text.isEmpty else { return nil }
        return Int(text)
    }

    private func profilerValue(named key: String, in output: String) -> String? {
        let prefix = "\(key):"
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func storageHardware(from output: String) -> StorageHardware? {
        var items: [StorageHardware] = []
        var current = StorageHardware()
        var hasCurrent = false
        var inPhysicalDrive = false

        func finishCurrent() {
            guard hasCurrent else { return }
            items.append(current)
        }

        for rawLine in output.components(separatedBy: .newlines) {
            let indent = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if indent == 4, line.hasSuffix(":") {
                finishCurrent()
                current = StorageHardware(volumeName: String(line.dropLast()))
                hasCurrent = true
                inPhysicalDrive = false
                continue
            }

            if line == "Physical Drive:" {
                inPhysicalDrive = true
                continue
            }

            let pair = keyValue(from: line)
            guard let key = pair.key else { continue }

            if inPhysicalDrive {
                switch key {
                case "Device Name": current.deviceName = pair.value
                case "Medium Type": current.mediumType = pair.value
                case "Protocol": current.protocolName = pair.value
                case "Internal": current.internalValue = pair.value
                default: break
                }
            } else {
                switch key {
                case "Mount Point": current.mountPoint = pair.value
                case "Capacity": current.capacity = pair.valueWithoutByteSuffix
                case "File System": current.fileSystem = pair.value
                case "BSD Name": current.bsdName = pair.value
                default: break
                }
            }
        }
        finishCurrent()

        return items.first { $0.mountPoint == "/" }
            ?? items.first { $0.mountPoint == "/System/Volumes/Data" }
            ?? items.first { $0.internalValue == "Yes" }
            ?? items.first
    }

    private func keyValue(from line: String) -> (key: String?, value: String, valueWithoutByteSuffix: String) {
        guard let colonIndex = line.firstIndex(of: ":") else {
            return (nil, "", "")
        }
        let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        let compactValue = value.components(separatedBy: " (").first ?? value
        return (key, value, compactValue)
    }

    private func gpuHeading(from output: String) -> String? {
        var sawHeader = false
        for rawLine in output.components(separatedBy: .newlines) {
            let indent = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Graphics/Displays:" {
                sawHeader = true
                continue
            }
            if sawHeader, indent == 4, line.hasSuffix(":") {
                return String(line.dropLast())
            }
        }
        return nil
    }

    private func wifiInterfaceName() -> String? {
        guard let output = commandOutput(
            executablePath: "/usr/sbin/networksetup",
            arguments: ["-listallhardwareports"],
            timeout: 1.0
        ) else { return nil }

        var previousLineWasWiFi = false
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "Hardware Port: Wi-Fi" || line == "Hardware Port: AirPort" {
                previousLineWasWiFi = true
                continue
            }
            if previousLineWasWiFi, line.hasPrefix("Device:") {
                return String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func currentSSID(interface: String) -> String {
        guard let output = commandOutput(
            executablePath: "/usr/sbin/networksetup",
            arguments: ["-getairportnetwork", interface],
            timeout: 1.0
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            return "未知"
        }
        if output.localizedCaseInsensitiveContains("not associated") {
            return "未连接"
        }
        if let colonIndex = output.firstIndex(of: ":") {
            return String(output[output.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    private func localizedWiFiStatus(_ status: String?) -> String {
        let raw = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.localizedCaseInsensitiveContains("not associated") {
            return "未连接"
        }
        if raw.localizedCaseInsensitiveContains("associated") {
            return "已连接"
        }
        return raw.isEmpty ? "未知" : raw
    }

    private func localizedYesNo(_ value: String) -> String {
        if value.localizedCaseInsensitiveCompare("Yes") == .orderedSame {
            return "是"
        }
        if value.localizedCaseInsensitiveCompare("No") == .orderedSame {
            return "否"
        }
        return value
    }

    func updateProcesses() {
        var processes: [AppProcess] = []
        var currentDiskTotals: [Int32: (read: UInt64, write: UInt64)] = [:]
        var totalDiskReadRate: Double = 0
        var totalDiskWriteRate: Double = 0
        let sampleTime = Date()
        let elapsed = previousProcessSampleTime.map { max(sampleTime.timeIntervalSince($0), 0.1) }
        let processorCount = max(Foundation.ProcessInfo.processInfo.activeProcessorCount, 1)
        let gpuSample = sampleGPUUsage()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,pcpu=,rss=,user=,command="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        let lines = output.components(separatedBy: "\n").dropFirst()

        let runningApps: [NSRunningApplication]
        if Thread.isMainThread {
            runningApps = NSWorkspace.shared.runningApplications
        } else {
            runningApps = DispatchQueue.main.sync {
                NSWorkspace.shared.runningApplications
            }
        }

        let appMap = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.processIdentifier, $0) })
        var currentProcessIDs = Set<Int32>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let components = trimmed.split(
                separator: " ",
                maxSplits: 5,
                omittingEmptySubsequences: true
            )
            guard components.count >= 6 else { continue }

            guard let pid = Int32(components[0]),
                  let parentPID = Int32(components[1]),
                  let cpu = Double(components[2]),
                  let rss = UInt64(components[3]) else { continue }

            currentProcessIDs.insert(pid)
            let user = String(components[4])
            let normalizedCPU = min(cpu / Double(processorCount), 100)
            let gpuUsage = gpuSample.processUsage[pid] ?? 0
            let command = String(components[5])
            let matchedApp = appMap[pid]
            let appIcon = icon(for: pid, app: matchedApp)
            let isApp = appIcon != nil && isApplicationProcess(command: command, app: matchedApp)
            let name = displayName(pid: pid, command: command, app: matchedApp, isApp: isApp)
            let icon: NSImage? = appIcon ?? fallbackProcessIcon
            let diskTotal = diskBytes(for: pid)
            let diskReadBytesPerSecond: Double
            let diskWriteBytesPerSecond: Double
            let diskBytesPerSecond: Double
            if let elapsed, let previousTotal = previousDiskTotals[pid] {
                diskReadBytesPerSecond = diskTotal.read >= previousTotal.read ? Double(diskTotal.read - previousTotal.read) / elapsed : 0
                diskWriteBytesPerSecond = diskTotal.write >= previousTotal.write ? Double(diskTotal.write - previousTotal.write) / elapsed : 0
                diskBytesPerSecond = diskReadBytesPerSecond + diskWriteBytesPerSecond
            } else {
                diskReadBytesPerSecond = 0
                diskWriteBytesPerSecond = 0
                diskBytesPerSecond = 0
            }
            totalDiskReadRate += diskReadBytesPerSecond
            totalDiskWriteRate += diskWriteBytesPerSecond
            currentDiskTotals[pid] = diskTotal
            let networkBytesPerSecond = networkRate(for: pid)

            guard !name.isEmpty else { continue }

            processes.append(AppProcess(
                pid: pid,
                parentPID: parentPID,
                name: name,
                cpuUsage: normalizedCPU,
                gpuUsage: gpuUsage,
                memoryUsage: rss * 1024,
                diskBytesPerSecond: diskBytesPerSecond,
                networkBytesPerSecond: networkBytesPerSecond,
                user: user,
                icon: icon,
                isApp: isApp,
                status: .none
            ))
        }

        previousDiskTotals = currentDiskTotals
        previousProcessSampleTime = sampleTime
        appIconCache = appIconCache.filter { currentProcessIDs.contains($0.key) }

        let sortedProcesses = sortProcessesByMemory(processes)
        let totalDiskRate = totalDiskReadRate + totalDiskWriteRate
        DispatchQueue.main.async {
            self.processVersion &+= 1
            self.totalGPU = gpuSample.totalUsage
            self.totalDiskBytesPerSecond = totalDiskRate
            self.diskReadBytesPerSecond = totalDiskReadRate
            self.diskWriteBytesPerSecond = totalDiskWriteRate
            self.appendHistory(min(totalDiskRate / (100 * 1_048_576) * 100, 100), to: &self.diskActivityHistory)
            self.appendHistory(min(totalDiskRate / 1_048_576, 100), to: &self.diskTransferHistory)
            self.appendHistory(gpuSample.totalUsage, to: &self.gpuHistory)
            self.processes = sortedProcesses
        }
    }

    private func icon(for pid: Int32, app: NSRunningApplication?) -> NSImage? {
        if let cachedIcon = appIconCache[pid] {
            return cachedIcon
        }
        guard let icon = app?.icon else { return nil }
        appIconCache[pid] = icon
        return icon
    }

    private func isApplicationProcess(command: String, app: NSRunningApplication?) -> Bool {
        if app?.activationPolicy == .regular {
            return true
        }
        if let bundlePath = app?.bundleURL?.path, isApplicationsBundlePath(bundlePath) {
            return true
        }
        return isApplicationsBundlePath(command)
    }

    private func isApplicationsBundlePath(_ path: String) -> Bool {
        let normalizedPath = (path.replacingOccurrences(of: "\\ ", with: " ") as NSString).standardizingPath
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard let appComponentIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return false
        }
        return components[..<appComponentIndex].contains("Applications")
    }

    private func sortProcessesByMemory(_ processes: [AppProcess]) -> [AppProcess] {
        processes.sorted {
            if $0.memoryUsage != $1.memoryUsage { return $0.memoryUsage > $1.memoryUsage }
            if $0.cpuUsage != $1.cpuUsage { return $0.cpuUsage > $1.cpuUsage }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func sampleGPUUsage() -> (processUsage: [Int32: Double], totalUsage: Double) {
        let totalUsage = currentGPUUtilization() ?? cachedTotalGPU
        cachedTotalGPU = totalUsage
        guard let output = commandOutput(
            executablePath: "/usr/sbin/ioreg",
            arguments: ["-r", "-d", "1", "-w0", "-c", "AGXDeviceUserClient"],
            timeout: 1.0
        ) else {
            return ([:], totalUsage)
        }

        let totals = gpuAccumulatedTimeByPID(from: output)
        let sampleTime = Date()
        guard let previousGPUSampleTime else {
            previousGPUTotals = totals
            self.previousGPUSampleTime = sampleTime
            return ([:], totalUsage)
        }

        let elapsed = max(sampleTime.timeIntervalSince(previousGPUSampleTime), 0.1)
        var usage: [Int32: Double] = [:]
        for (pid, total) in totals {
            guard let previousTotal = previousGPUTotals[pid], total >= previousTotal else { continue }
            let activeSeconds = Double(total - previousTotal) / 1_000_000_000
            let percent = min(activeSeconds / elapsed * 100, 100)
            if percent >= 0.05 {
                usage[pid] = percent
            }
        }

        previousGPUTotals = totals
        self.previousGPUSampleTime = sampleTime
        return (usage, totalUsage)
    }

    private func currentGPUUtilization() -> Double? {
        guard let output = commandOutput(
            executablePath: "/usr/sbin/ioreg",
            arguments: ["-r", "-d", "1", "-w0", "-c", "IOAccelerator"],
            timeout: 0.8
        ) else {
            return nil
        }
        return numericIORegValue(named: "Device Utilization %", in: output)
    }

    private func gpuAccumulatedTimeByPID(from output: String) -> [Int32: UInt64] {
        var totals: [Int32: UInt64] = [:]
        let blocks = output.components(separatedBy: "+-o AGXDeviceUserClient")
        for block in blocks {
            guard let pid = gpuClientPID(from: block) else { continue }
            let accumulatedTime = accumulatedGPUTime(in: block)
            guard accumulatedTime > 0 else { continue }
            totals[pid, default: 0] += accumulatedTime
        }
        return totals
    }

    private func gpuClientPID(from block: String) -> Int32? {
        let pattern = "\"IOUserClientCreator\"\\s*=\\s*\"pid\\s+(\\d+),"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        guard let match = regex.firstMatch(in: block, range: range),
              let pidRange = Range(match.range(at: 1), in: block) else {
            return nil
        }
        return Int32(block[pidRange])
    }

    private func accumulatedGPUTime(in block: String) -> UInt64 {
        let pattern = "\"accumulatedGPUTime\"\\s*=\\s*(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        let matches = regex.matches(in: block, range: range)
        return matches.reduce(UInt64(0)) { total, match in
            guard let valueRange = Range(match.range(at: 1), in: block),
                  let value = UInt64(block[valueRange]) else {
                return total
            }
            return total + value
        }
    }

    private func numericIORegValue(named key: String, in output: String) -> Double? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*=\\s*(-?\\d+(?:\\.\\d+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let valueRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Double(output[valueRange])
    }

    private func commandOutput(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try task.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
            }
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func displayName(pid: Int32, command: String, app: NSRunningApplication?, isApp: Bool) -> String {
        if isApp {
            if let localizedName = app?.localizedName, !localizedName.isEmpty {
                return localizedName
            }
            if let bundleName = app?.bundleURL?.deletingPathExtension().lastPathComponent, !bundleName.isEmpty {
                return bundleName
            }
        }

        var nameBuffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
            let procName = String(cString: nameBuffer)
            if !procName.isEmpty {
                return procName
            }
        }

        let executable = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? command
        let lastPathComponent = (executable as NSString).lastPathComponent
        return lastPathComponent.isEmpty ? executable : lastPathComponent
    }

    private func diskBytes(for pid: Int32) -> (read: UInt64, write: UInt64) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return (0, 0) }
        return (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
    }

    private func networkRate(for pid: Int32) -> Double {
        networkLock.lock()
        defer { networkLock.unlock() }
        return networkRates[pid] ?? 0
    }

    private func scheduleNetworkRateUpdate() {
        networkLock.lock()
        if isNetworkSampling {
            networkLock.unlock()
            return
        }
        isNetworkSampling = true
        networkLock.unlock()

        networkQueue.async {
            self.updateNetworkRates()
            self.networkLock.lock()
            self.isNetworkSampling = false
            self.networkLock.unlock()
        }
    }

    private func updateNetworkRates() {
        let totals = networkBytesByPID()
        let sampleTime = Date()
        guard let previousSampleTime = previousNetworkSampleTime else {
            previousNetworkTotals = totals
            previousNetworkSampleTime = sampleTime
            return
        }

        let elapsed = max(sampleTime.timeIntervalSince(previousSampleTime), 0.1)
        var rates: [Int32: Double] = [:]
        var receiveRate: Double = 0
        var sendRate: Double = 0
        for (pid, total) in totals {
            guard let previousTotal = previousNetworkTotals[pid] else { continue }
            let received = total.received >= previousTotal.received ? Double(total.received - previousTotal.received) / elapsed : 0
            let sent = total.sent >= previousTotal.sent ? Double(total.sent - previousTotal.sent) / elapsed : 0
            rates[pid] = received + sent
            receiveRate += received
            sendRate += sent
        }

        previousNetworkTotals = totals
        previousNetworkSampleTime = sampleTime
        networkLock.lock()
        networkRates = rates
        networkLock.unlock()

        let totalRate = receiveRate + sendRate
        DispatchQueue.main.async {
            self.networkReceiveBytesPerSecond = receiveRate
            self.networkSendBytesPerSecond = sendRate
            self.totalNetworkBytesPerSecond = totalRate
            self.appendHistory(min(totalRate * 8 / 1_000_000, 1), to: &self.wifiThroughputHistory)
        }
    }

    private func networkBytesByPID() -> [Int32: (received: UInt64, sent: UInt64)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try task.run()
        } catch {
            return [:]
        }

        if finished.wait(timeout: .now() + 2.5) == .timedOut {
            task.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        var totals: [Int32: (received: UInt64, sent: UInt64)] = [:]

        for line in output.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let processIDPart = String(parts[0])
            guard let dotIndex = processIDPart.lastIndex(of: "."),
                  let pid = Int32(processIDPart[processIDPart.index(after: dotIndex)...]),
                  let bytesIn = UInt64(parts[1]),
                  let bytesOut = UInt64(parts[2]) else { continue }
            totals[pid] = (bytesIn, bytesOut)
        }

        return totals
    }

    func updateCPUCores() {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let err = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )

        guard err == KERN_SUCCESS, let cpuInfo = cpuInfo else { return }

        var cores: [CPUCore] = []
        var currentCoreInfo: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        var totalUsage: Double = 0
        let hadPreviousCoreInfo = !previousCoreInfo.isEmpty

        for i in 0..<Int(numCPUs) {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt32(cpuInfo[base + Int(CPU_STATE_USER)])
            let system = UInt32(cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(cpuInfo[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(cpuInfo[base + Int(CPU_STATE_NICE)])

            currentCoreInfo.append((user, system, idle, nice))

            var usage: Double = 0
            if i < previousCoreInfo.count {
                let prev = previousCoreInfo[i]
                let userDiff = Double(user &- prev.user)
                let systemDiff = Double(system &- prev.system)
                let idleDiff = Double(idle &- prev.idle)
                let niceDiff = Double(nice &- prev.nice)
                let total = userDiff + systemDiff + idleDiff + niceDiff
                if total > 0 {
                    usage = ((userDiff + systemDiff + niceDiff) / total) * 100
                }
            }

            totalUsage += usage
            cores.append(CPUCore(id: i, usage: usage))
        }

        previousCoreInfo = currentCoreInfo

        // 释放内存
        let cpuInfoSize = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), cpuInfoSize)

        let avgCPU = cores.isEmpty ? 0 : totalUsage / Double(cores.count)

        DispatchQueue.main.async {
            self.cpuCores = cores
            self.totalCPU = avgCPU
            if hadPreviousCoreInfo {
                self.appendCPUCoreHistories(cores.map(\.usage))
            }
        }
    }

    func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let active = UInt64(stats.active_count)
            let wired = UInt64(stats.wire_count)
            let compressed = UInt64(stats.compressor_page_count)

            let used = (active + wired + compressed) * pageSize
            let total = Foundation.ProcessInfo.processInfo.physicalMemory

            DispatchQueue.main.async {
                self.usedMemory = used
                self.totalMemory = total
                self.appendHistory(Double(used) / Double(max(total, 1)) * 100, to: &self.memoryHistory)
            }
        }
    }

    private func appendCPUCoreHistories(_ usages: [Double]) {
        if cpuCoreHistories.count != usages.count {
            cpuCoreHistories = Array(repeating: [], count: usages.count)
        }
        for index in usages.indices {
            appendHistory(usages[index], to: &cpuCoreHistories[index])
        }
    }

    private func appendHistory(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > performanceHistoryLimit {
            history.removeFirst(history.count - performanceHistoryLimit)
        }
    }

    func updatePorts() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]

        let pipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        var ports: [PortEntry] = []
        var seen = Set<String>()
        let lines = output.components(separatedBy: "\n").dropFirst()

        for line in lines {
            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 9 else { continue }

            let process = components[0]
            let pid = components[1]
            let portInfo = components[8]

            if let port = portInfo.components(separatedBy: ":").last {
                let key = "\(pid)-\(port)"
                if !seen.contains(key) {
                    seen.insert(key)
                    ports.append(PortEntry(
                        port: port,
                        process: process,
                        pid: pid,
                        proto: "TCP"
                    ))
                }
            }
        }

        DispatchQueue.main.async {
            self.ports = ports.sorted { (Int($0.port) ?? 0) < (Int($1.port) ?? 0) }
        }
    }

    func killProcess(pid: Int32, name: String? = nil) {
        _ = name
        guard kill(pid, SIGTERM) == 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.updateData()
        }
    }

    func launchTask(command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", trimmed]

        do {
            try task.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.updateData()
            }
            return true
        } catch {
            return false
        }
    }

    func enableEfficiencyMode(pid: Int32) -> Bool {
        setpriority(PRIO_PROCESS, id_t(pid), 10) == 0
    }

    deinit {
        timer?.invalidate()
    }
}

final class ContentViewState: ObservableObject {
    @Published var selectedNav = 0
    @Published var sidebarExpanded = false
    @Published var searchText = ""
    @Published var selectedPID: Int32?
    @Published var showRunTaskDialog = false
    @Published var runTaskCommand = ""
    @Published var runTaskError = ""
    @Published var efficiencyPIDs: Set<Int32> = []
    @Published var frozenProcessOrder: [Int32]?
    @Published var expandedProcessIDs: Set<Int32> = []
    @Published var selectedPerformanceIndex = 0

    private var processTableCacheKey: ProcessTableCacheKey?
    private var processTableCache: ProcessTableData?

    func processTableData(processes: [AppProcess], processVersion: Int) -> ProcessTableData {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ProcessTableCacheKey(
            processVersion: processVersion,
            searchText: normalizedSearch,
            frozenProcessOrder: frozenProcessOrder,
            expandedProcessIDs: expandedProcessIDs.sorted()
        )

        if processTableCacheKey == key, let processTableCache {
            return processTableCache
        }

        let tableData = ProcessTableData.make(
            processes: processes,
            searchText: normalizedSearch,
            frozenProcessOrder: frozenProcessOrder,
            expandedProcessIDs: expandedProcessIDs
        )
        processTableCacheKey = key
        processTableCache = tableData
        return tableData
    }
}

enum TaskManagerStyle {
    static let contentWidth: CGFloat = 1023
    static let contentHeight: CGFloat = 726
    static let minContentWidth: CGFloat = 860
    static let minContentHeight: CGFloat = 520
    static let shadowMargin: CGFloat = 0
    static let cornerRadius: CGFloat = 8
    static let chrome = Color(red: 0.937, green: 0.949, blue: 0.973)
    static let sidebar = Color(red: 0.929, green: 0.949, blue: 0.976)
    static let selectedSidebar = Color(red: 0.910, green: 0.918, blue: 0.941)
    static let hoveredSidebar = Color(red: 0.945, green: 0.945, blue: 0.945)
    static let grid = Color(red: 0.914, green: 0.914, blue: 0.914)
    static let chromeRule = Color(red: 0.886, green: 0.898, blue: 0.918)
    static let headerCell = Color(red: 0.965, green: 0.965, blue: 0.965)
    static let resource = Color(red: 0.839, green: 0.945, blue: 1.000)
    static let resourceHot = Color(red: 0.612, green: 0.867, blue: 1.000)
    static let selectedRow = Color(red: 0.972, green: 0.972, blue: 0.972)
    static let text = Color(red: 0.055, green: 0.067, blue: 0.082)
    static let muted = Color(red: 0.365, green: 0.392, blue: 0.431)
}

struct ResourceSample {
    let cpuUsage: Double
    let gpuUsage: Double
    let memoryUsage: UInt64
    let diskBytesPerSecond: Double
    let networkBytesPerSecond: Double
}

struct ProcessResourceValues {
    var cpuUsage: Double
    var gpuUsage: Double
    var memoryUsage: UInt64
    var diskBytesPerSecond: Double
    var networkBytesPerSecond: Double

    static func from(_ process: AppProcess) -> ProcessResourceValues {
        ProcessResourceValues(
            cpuUsage: process.cpuUsage,
            gpuUsage: process.gpuUsage,
            memoryUsage: process.memoryUsage,
            diskBytesPerSecond: process.diskBytesPerSecond,
            networkBytesPerSecond: process.networkBytesPerSecond
        )
    }

    mutating func add(_ values: ProcessResourceValues) {
        cpuUsage += values.cpuUsage
        gpuUsage += values.gpuUsage
        memoryUsage += values.memoryUsage
        diskBytesPerSecond += values.diskBytesPerSecond
        networkBytesPerSecond += values.networkBytesPerSecond
    }
}

struct ProcessTreeRow: Identifiable {
    var id: Int32 { process.pid }
    let process: AppProcess
    let resources: ProcessResourceValues
    let level: Int
    let hasChildren: Bool
    let childCount: Int
    let isExpanded: Bool
}

struct ProcessTableData {
    let filteredProcesses: [AppProcess]
    let appRootProcesses: [AppProcess]
    let backgroundRootProcesses: [AppProcess]
    let appProcessRows: [ProcessTreeRow]
    let backgroundProcessRows: [ProcessTreeRow]

    static func make(
        processes: [AppProcess],
        searchText: String,
        frozenProcessOrder: [Int32]?,
        expandedProcessIDs: Set<Int32>
    ) -> ProcessTableData {
        let matchingProcesses = processes.filter { process in
            searchText.isEmpty ||
                process.name.localizedCaseInsensitiveContains(searchText) ||
                process.user.localizedCaseInsensitiveContains(searchText) ||
                String(process.pid).contains(searchText)
        }
        let normallySorted = normallySortedProcesses(matchingProcesses)
        let filteredProcesses = frozenSortedProcesses(normallySorted, frozenProcessOrder: frozenProcessOrder)
        let visiblePIDs = Set(filteredProcesses.map(\.pid))
        let childrenByParent = Dictionary(
            grouping: filteredProcesses.filter { $0.parentPID > 1 && visiblePIDs.contains($0.parentPID) },
            by: \.parentPID
        )
        let rootProcesses = filteredProcesses.filter { $0.parentPID <= 1 || !visiblePIDs.contains($0.parentPID) }
        let appRootProcesses = rootProcesses.filter { $0.isApp }
        let backgroundRootProcesses = rootProcesses.filter { !$0.isApp }
        let resourcesByPID = aggregateResourcesByPID(
            processes: filteredProcesses,
            childrenByParent: childrenByParent
        )

        return ProcessTableData(
            filteredProcesses: filteredProcesses,
            appRootProcesses: appRootProcesses,
            backgroundRootProcesses: backgroundRootProcesses,
            appProcessRows: visibleRows(
                for: appRootProcesses,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs
            ),
            backgroundProcessRows: visibleRows(
                for: backgroundRootProcesses,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs
            )
        )
    }

    private static func normallySortedProcesses(_ processes: [AppProcess]) -> [AppProcess] {
        processes.sorted {
            if $0.isApp != $1.isApp { return $0.isApp && !$1.isApp }
            if $0.memoryUsage != $1.memoryUsage { return $0.memoryUsage > $1.memoryUsage }
            if $0.cpuUsage != $1.cpuUsage { return $0.cpuUsage > $1.cpuUsage }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func frozenSortedProcesses(
        _ normallySorted: [AppProcess],
        frozenProcessOrder: [Int32]?
    ) -> [AppProcess] {
        guard let frozenProcessOrder else { return normallySorted }

        let frozenRank = Dictionary(uniqueKeysWithValues: frozenProcessOrder.enumerated().map { ($0.element, $0.offset) })
        let normalRank = Dictionary(uniqueKeysWithValues: normallySorted.enumerated().map { ($0.element.pid, $0.offset) })
        return normallySorted.sorted {
            let leftFrozenRank = frozenRank[$0.pid] ?? Int.max
            let rightFrozenRank = frozenRank[$1.pid] ?? Int.max
            if leftFrozenRank != rightFrozenRank {
                return leftFrozenRank < rightFrozenRank
            }
            return (normalRank[$0.pid] ?? Int.max) < (normalRank[$1.pid] ?? Int.max)
        }
    }

    private static func visibleRows(
        for roots: [AppProcess],
        childrenByParent: [Int32: [AppProcess]],
        resourcesByPID: [Int32: ProcessResourceValues],
        expandedProcessIDs: Set<Int32>
    ) -> [ProcessTreeRow] {
        var rows: [ProcessTreeRow] = []
        var visitedPIDs = Set<Int32>()
        for process in roots {
            appendVisibleRows(
                for: process,
                level: 0,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs,
                visitedPIDs: &visitedPIDs,
                rows: &rows
            )
        }
        return rows
    }

    private static func appendVisibleRows(
        for process: AppProcess,
        level: Int,
        childrenByParent: [Int32: [AppProcess]],
        resourcesByPID: [Int32: ProcessResourceValues],
        expandedProcessIDs: Set<Int32>,
        visitedPIDs: inout Set<Int32>,
        rows: inout [ProcessTreeRow]
    ) {
        guard !visitedPIDs.contains(process.pid) else { return }
        visitedPIDs.insert(process.pid)

        let children = childrenByParent[process.pid] ?? []
        let isExpanded = expandedProcessIDs.contains(process.pid)
        rows.append(ProcessTreeRow(
            process: process,
            resources: resourcesByPID[process.pid] ?? .from(process),
            level: level,
            hasChildren: !children.isEmpty,
            childCount: children.count,
            isExpanded: isExpanded
        ))

        guard isExpanded else { return }
        for child in children {
            appendVisibleRows(
                for: child,
                level: level + 1,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs,
                visitedPIDs: &visitedPIDs,
                rows: &rows
            )
        }
    }

    private static func aggregateResourcesByPID(
        processes: [AppProcess],
        childrenByParent: [Int32: [AppProcess]]
    ) -> [Int32: ProcessResourceValues] {
        let processesByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var memo: [Int32: ProcessResourceValues] = [:]
        var visiting = Set<Int32>()

        for process in processes {
            _ = aggregateResources(
                for: process.pid,
                processesByPID: processesByPID,
                childrenByParent: childrenByParent,
                visiting: &visiting,
                memo: &memo
            )
        }
        return memo
    }

    private static func aggregateResources(
        for pid: Int32,
        processesByPID: [Int32: AppProcess],
        childrenByParent: [Int32: [AppProcess]],
        visiting: inout Set<Int32>,
        memo: inout [Int32: ProcessResourceValues]
    ) -> ProcessResourceValues {
        if let cached = memo[pid] {
            return cached
        }
        guard let process = processesByPID[pid] else {
            return ProcessResourceValues(cpuUsage: 0, gpuUsage: 0, memoryUsage: 0, diskBytesPerSecond: 0, networkBytesPerSecond: 0)
        }
        guard !visiting.contains(pid) else {
            return .from(process)
        }

        visiting.insert(pid)
        var total = ProcessResourceValues.from(process)
        for child in childrenByParent[pid] ?? [] {
            total.add(aggregateResources(
                for: child.pid,
                processesByPID: processesByPID,
                childrenByParent: childrenByParent,
                visiting: &visiting,
                memo: &memo
            ))
        }
        visiting.remove(pid)
        memo[pid] = total
        return total
    }
}

struct ProcessTableCacheKey: Equatable {
    let processVersion: Int
    let searchText: String
    let frozenProcessOrder: [Int32]?
    let expandedProcessIDs: [Int32]
}

// MARK: - Views
struct ContentView: View {
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var state = ContentViewState()

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 0) {
                TaskManagerTitleBar(state: state)

                HStack(spacing: 0) {
                    TaskManagerSidebar(state: state)

                    VStack(spacing: 0) {
                        if state.selectedNav == 0 {
                            TaskManagerCommandBar(monitor: monitor, state: state)
                            TaskManagerProcessTable(monitor: monitor, state: state)
                        } else {
                            TaskManagerSecondaryPage(index: state.selectedNav, monitor: monitor, state: state)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        TaskManagerFocus.clearSearchFocus()
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: TaskManagerStyle.cornerRadius, style: .continuous)
                    .fill(Color.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: TaskManagerStyle.cornerRadius, style: .continuous))
            .padding(TaskManagerStyle.shadowMargin)
        }
        .frame(
            minWidth: TaskManagerStyle.minContentWidth + TaskManagerStyle.shadowMargin * 2,
            maxWidth: .infinity,
            minHeight: TaskManagerStyle.minContentHeight + TaskManagerStyle.shadowMargin * 2,
            maxHeight: .infinity
        )
        .background(Color.clear)
        .sheet(isPresented: $state.showRunTaskDialog) {
            RunTaskDialog(monitor: monitor, state: state)
        }
        .onAppear {
            state.selectedPID = nil
        }
    }
}

private enum TaskManagerFocus {
    static func clearSearchFocus() {
        NotificationCenter.default.post(name: .taskManagerClearSearchFocus, object: nil)
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

private extension Notification.Name {
    static let taskManagerClearSearchFocus = Notification.Name("TaskManagerClearSearchFocus")
}

struct TaskManagerTitleBar: View {
    @ObservedObject var state: ContentViewState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                HStack(spacing: 28) {
                    ZStack {
                        Rectangle()
                            .fill(Color(red: 0.184, green: 0.655, blue: 0.882))
                            .frame(width: 20, height: 16)
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Text("任务管理器")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(TaskManagerStyle.text)
                }
                .frame(width: 272, alignment: .leading)
                .padding(.leading, 22)

                if state.selectedNav != 1 {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundColor(TaskManagerStyle.muted)
                        ZStack(alignment: .leading) {
                            if state.searchText.isEmpty && !searchFocused {
                                Text("键入要搜索的名称、发布者或 PID")
                                    .font(.system(size: 16))
                                    .foregroundColor(Color(red: 0.620, green: 0.640, blue: 0.670))
                            }
                            TextField("", text: $state.searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 16))
                                .focused($searchFocused)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(width: 346, height: 40)
                    .background(Color(red: 0.980, green: 0.980, blue: 0.988))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color(red: 0.886, green: 0.898, blue: 0.918), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .offset(y: -1)
                }

                Spacer()

                HStack(spacing: 0) {
                    WindowControlButton(icon: "minus") {
                        NSApp.keyWindow?.miniaturize(nil)
                    }
                    WindowControlButton(icon: "square") {
                        NSApp.keyWindow?.zoom(nil)
                    }
                    WindowControlButton(icon: "xmark", isClose: true) {
                        NSApp.terminate(nil)
                    }
                }
                .frame(height: 64, alignment: .top)
            }
            .frame(height: 64)
            .background(TaskManagerStyle.chrome)

            Rectangle()
                .fill(TaskManagerStyle.chromeRule)
                .frame(height: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .taskManagerClearSearchFocus)) { _ in
            searchFocused = false
        }
    }
}

final class WindowControlHoverState: ObservableObject {
    @Published var isHovered = false
}

struct WindowControlButton: View {
    let icon: String
    var isClose = false
    let action: () -> Void
    @StateObject private var hover = WindowControlHoverState()

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(backgroundColor)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(iconColor)
            }
            .frame(width: 46, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hover.isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        guard hover.isHovered else { return .clear }
        if isClose {
            return Color(red: 0.769, green: 0.188, blue: 0.137)
        }
        return Color.black.opacity(0.075)
    }

    private var iconColor: Color {
        hover.isHovered && isClose ? .white : .black
    }
}

struct TaskManagerSidebar: View {
    @ObservedObject var state: ContentViewState

    let icons = [
        "square.grid.2x2",
        "waveform.path.ecg",
        "clock.arrow.circlepath",
        "speedometer",
        "person.2",
        "list.bullet",
        "gearshape"
    ]
    let labels = [
        "进程",
        "性能",
        "应用历史记录",
        "启动应用",
        "用户",
        "详细信息",
        "服务"
    ]

    var sidebarWidth: CGFloat {
        state.sidebarExpanded ? 190 : 62
    }

    var body: some View {
        VStack(spacing: 8) {
            SidebarToggleButton(expanded: state.sidebarExpanded) {
                state.sidebarExpanded.toggle()
            }
                .padding(.top, 7)

            ForEach(Array(icons.enumerated()), id: \.offset) { item in
                SidebarButton(
                    icon: item.element,
                    label: labels[item.offset],
                    expanded: state.sidebarExpanded,
                    selected: state.selectedNav == item.offset
                ) {
                    state.selectedNav = item.offset
                }
            }

            Spacer()

            SidebarButton(icon: "gearshape", label: "设置", expanded: state.sidebarExpanded, selected: false) {}
                .padding(.bottom, 14)
        }
        .frame(width: sidebarWidth)
        .background(TaskManagerStyle.sidebar)
        .animation(.easeInOut(duration: 0.16), value: state.sidebarExpanded)
    }
}

struct SidebarToggleButton: View {
    let expanded: Bool
    let action: () -> Void
    @StateObject private var hover = SidebarButtonHoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SidebarSystemIcon(icon: "line.3.horizontal")
                    .frame(width: 50, height: 42)
                if expanded {
                    Text("导航")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(TaskManagerStyle.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: expanded ? 176 : 50, height: 42, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hover.isHovered ? TaskManagerStyle.hoveredSidebar : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .frame(width: expanded ? 176 : 50, height: 42, alignment: .leading)
        .onHover { hovering in
            hover.isHovered = hovering
        }
    }
}

struct SidebarButton: View {
    let icon: String
    let label: String
    let expanded: Bool
    let selected: Bool
    let action: () -> Void
    @StateObject private var hover = SidebarButtonHoverState()

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(backgroundColor)
                    .frame(width: expanded ? 176 : 50, height: selected ? 44 : 42)
                    .offset(x: selected ? -1 : 0, y: selected ? 2 : 0)
                if selected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(red: 0.000, green: 0.404, blue: 0.753))
                        .frame(width: 5, height: 20)
                        .offset(x: -2, y: 1)
                }
                HStack(spacing: 12) {
                    SidebarFluentIcon(icon: icon)
                        .frame(width: 50, height: 42)
                    if expanded {
                        Text(label)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(TaskManagerStyle.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: expanded ? 176 : 50, height: 42, alignment: .leading)
        }
        .buttonStyle(.plain)
        .frame(width: expanded ? 176 : 50, height: 42, alignment: .leading)
        .onHover { hovering in
            hover.isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        if selected {
            return TaskManagerStyle.selectedSidebar
        }
        return hover.isHovered ? TaskManagerStyle.hoveredSidebar : Color.clear
    }
}

final class SidebarButtonHoverState: ObservableObject {
    @Published var isHovered = false
}

struct SidebarFluentIcon: View {
    let icon: String

    var body: some View {
        ZStack {
            switch icon {
            case "square.grid.2x2":
                ProcessGlyph()
                    .stroke(TaskManagerStyle.text, style: SidebarIconMetrics.strokeStyle)
                    .frame(width: SidebarIconMetrics.glyphSize, height: SidebarIconMetrics.glyphSize)
            case "waveform.path.ecg":
                PerformanceGlyph()
                    .stroke(TaskManagerStyle.text, style: SidebarIconMetrics.strokeStyle)
                    .frame(width: SidebarIconMetrics.glyphSize, height: SidebarIconMetrics.glyphSize)
            default:
                SidebarSystemIcon(icon: icon)
            }
        }
        .frame(width: SidebarIconMetrics.canvasSize, height: SidebarIconMetrics.canvasSize, alignment: .center)
    }
}

private enum SidebarIconMetrics {
    static let canvasSize: CGFloat = 24
    static let glyphSize: CGFloat = 20
    static let symbolSize: CGFloat = 19
    static let strokeStyle = StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
}

struct SidebarSystemIcon: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: SidebarIconMetrics.symbolSize, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundColor(TaskManagerStyle.text)
            .frame(width: SidebarIconMetrics.canvasSize, height: SidebarIconMetrics.canvasSize, alignment: .center)
    }
}

struct ProcessGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bounds = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        let splitX = bounds.minX + bounds.width * 0.48
        let splitY = bounds.minY + bounds.height * 0.48
        let outerRadius = bounds.width * 0.13
        let innerRadius = bounds.width * 0.08

        path.move(to: CGPoint(x: bounds.minX + outerRadius, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX - outerRadius, y: bounds.minY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX, y: bounds.minY + outerRadius),
            control: CGPoint(x: bounds.maxX, y: bounds.minY)
        )
        path.addLine(to: CGPoint(x: bounds.maxX, y: splitY - outerRadius))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX - outerRadius, y: splitY),
            control: CGPoint(x: bounds.maxX, y: splitY)
        )
        path.addLine(to: CGPoint(x: splitX + innerRadius, y: splitY))
        path.addQuadCurve(
            to: CGPoint(x: splitX, y: splitY + innerRadius),
            control: CGPoint(x: splitX, y: splitY)
        )
        path.addLine(to: CGPoint(x: splitX, y: bounds.maxY - outerRadius))
        path.addQuadCurve(
            to: CGPoint(x: splitX - outerRadius, y: bounds.maxY),
            control: CGPoint(x: splitX, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.minX + outerRadius, y: bounds.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX, y: bounds.maxY - outerRadius),
            control: CGPoint(x: bounds.minX, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + outerRadius))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX + outerRadius, y: bounds.minY),
            control: CGPoint(x: bounds.minX, y: bounds.minY)
        )
        path.closeSubpath()

        path.move(to: CGPoint(x: splitX, y: bounds.minY + outerRadius * 0.25))
        path.addLine(to: CGPoint(x: splitX, y: splitY - innerRadius * 0.3))
        path.move(to: CGPoint(x: bounds.minX + outerRadius * 0.25, y: splitY))
        path.addLine(to: CGPoint(x: splitX - innerRadius * 0.3, y: splitY))
        return path
    }
}

struct PerformanceGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect.insetBy(dx: 1.3, dy: 1.3), cornerSize: CGSize(width: 4.2, height: 4.2))
        let y = rect.midY + 1
        path.move(to: CGPoint(x: rect.minX + 4.1, y: y))
        path.addLine(to: CGPoint(x: rect.minX + 7.1, y: y))
        path.addLine(to: CGPoint(x: rect.minX + 9.0, y: rect.minY + 5.0))
        path.addLine(to: CGPoint(x: rect.minX + 12.0, y: rect.maxY - 4.2))
        path.addLine(to: CGPoint(x: rect.minX + 14.2, y: y))
        path.addLine(to: CGPoint(x: rect.maxX - 4.2, y: y))
        return path
    }
}

struct TaskManagerCommandBar: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: ContentViewState

    var selectedProcess: AppProcess? {
        guard let pid = state.selectedPID else { return nil }
        return monitor.processes.first { $0.pid == pid }
    }

    var canEndTask: Bool {
        selectedProcess != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("进程")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(TaskManagerStyle.text)
                .padding(.leading, 20)

            Spacer()

            CommandButton(icon: "macwindow.badge.plus", title: "运行新任务", enabled: true) {
                state.showRunTaskDialog = true
            }

            CommandSeparator()
                .offset(x: -3)

            CommandButton(icon: "nosign", title: "结束任务", enabled: canEndTask) {
                if let process = selectedProcess {
                    confirmKill(process)
                }
            }

            CommandButton(icon: "leaf", title: "效率模式", enabled: selectedProcess != nil) {
                if let process = selectedProcess {
                    if monitor.enableEfficiencyMode(pid: process.pid) {
                        state.efficiencyPIDs.insert(process.pid)
                    } else {
                        showFailure("无法开启效率模式", detail: "可能没有权限调整 PID \(process.pid) 的优先级。")
                    }
                }
            }

            Button(action: showOverflowMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 48, height: 40)
                    .foregroundColor(TaskManagerStyle.text)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 63)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TaskManagerStyle.grid)
                .frame(height: 1)
        }
    }

    func confirmKill(_ process: AppProcess) {
        let alert = NSAlert()
        alert.messageText = "结束任务 \(process.name)?"
        alert.informativeText = "PID: \(process.pid) - 未保存的数据可能丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "结束任务")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            monitor.killProcess(pid: process.pid, name: process.name)
        }
    }

    func showFailure(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    func showOverflowMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "刷新", action: #selector(OverflowMenuActions.refresh), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "复制 PID", action: #selector(OverflowMenuActions.copyPID), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "复制进程名", action: #selector(OverflowMenuActions.copyName), keyEquivalent: ""))
        OverflowMenuActions.shared.monitor = monitor
        OverflowMenuActions.shared.state = state
        OverflowMenuActions.shared.selectedProcess = selectedProcess
        for item in menu.items {
            item.target = OverflowMenuActions.shared
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

final class OverflowMenuActions: NSObject {
    static let shared = OverflowMenuActions()
    weak var monitor: SystemMonitor?
    weak var state: ContentViewState?
    var selectedProcess: AppProcess?

    @objc func refresh() {
        monitor?.updateData()
    }

    @objc func copyPID() {
        guard let pid = state?.selectedPID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(pid), forType: .string)
    }

    @objc func copyName() {
        guard let name = selectedProcess?.name else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

}

struct CommandButton: View {
    let icon: String
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(.system(size: 14))
            }
            .offset(y: -2)
            .foregroundColor(enabled ? TaskManagerStyle.text : Color(red: 0.639, green: 0.639, blue: 0.639))
            .frame(height: 40)
            .padding(.horizontal, 18)
        }
        .buttonStyle(.plain)
    }
}

struct CommandSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(red: 0.941, green: 0.941, blue: 0.941))
            .frame(width: 1, height: 32)
    }
}

struct RunTaskDialog: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: ContentViewState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("创建新任务")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }

            Text("输入程序、文件夹、文档或 Internet 资源的名称，系统将为你打开它。")
                .font(.system(size: 13))
                .foregroundColor(TaskManagerStyle.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("例如：open -a Safari 或 /Applications/Safari.app", text: $state.runTaskCommand)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))

            if !state.runTaskError.isEmpty {
                Text(state.runTaskError)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消") {
                    state.runTaskError = ""
                    dismiss()
                }
                Button("确定") {
                    if monitor.launchTask(command: state.runTaskCommand) {
                        state.runTaskCommand = ""
                        state.runTaskError = ""
                        dismiss()
                    } else {
                        state.runTaskError = "无法启动该任务，请检查命令或路径。"
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

struct TaskManagerSecondaryPage: View {
    let index: Int
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: ContentViewState

    let titles = [
        "进程",
        "性能",
        "应用历史记录",
        "启动应用",
        "用户",
        "详细信息",
        "服务"
    ]

    var title: String {
        titles.indices.contains(index) ? titles[index] : "进程"
    }

    var memoryPercent: Double {
        guard monitor.totalMemory > 0 else { return 0 }
        return Double(monitor.usedMemory) / Double(monitor.totalMemory) * 100
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(TaskManagerStyle.text)
                    .padding(.leading, 20)
                Spacer()
                if index == 1 {
                    CommandButton(icon: "macwindow.badge.plus", title: "运行新任务", enabled: true) {
                        state.showRunTaskDialog = true
                    }
                    CommandSeparator()
                    Button(action: {}) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 48, height: 40)
                            .foregroundColor(TaskManagerStyle.text)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 63)
            .background(Color.white)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TaskManagerStyle.grid)
                    .frame(height: 1)
            }

            if index == 1 {
                PerformancePage(monitor: monitor, state: state)
            } else if index == 2 {
                SimpleDataTable(columns: ["名称", "CPU", "内存"], rows: appRows)
            } else if index == 3 {
                SimpleDataTable(columns: ["名称", "状态", "影响"], rows: startupRows)
            } else if index == 4 {
                SimpleDataTable(columns: ["用户", "进程数", "内存"], rows: userRows)
            } else if index == 5 {
                SimpleDataTable(columns: ["名称", "PID", "用户", "CPU", "内存"], rows: detailRows)
            } else if index == 6 {
                SimpleDataTable(columns: ["名称", "PID", "端口", "协议"], rows: serviceRows)
            } else {
                Text("\(title) 页面")
                    .font(.system(size: 16))
                    .foregroundColor(TaskManagerStyle.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .background(Color.white)
    }

    var appRows: [[String]] {
        monitor.processes
            .filter { $0.isApp }
            .sorted { $0.name < $1.name }
            .map { [$0.name, formatCPU($0.cpuUsage), formatMemory($0.memoryUsage)] }
    }

    var startupRows: [[String]] {
        monitor.processes
            .filter { $0.isApp }
            .sorted { $0.name < $1.name }
            .map { [$0.name, "可用", $0.cpuUsage > 2 ? "高" : "低"] }
    }

    var userRows: [[String]] {
        let groups = Dictionary(grouping: monitor.processes, by: { $0.user })
        return groups.keys.sorted().map { user in
            let items = groups[user] ?? []
            let memory = items.reduce(UInt64(0)) { $0 + $1.memoryUsage }
            return [user, "\(items.count)", formatMemory(memory)]
        }
    }

    var detailRows: [[String]] {
        monitor.processes
            .sorted { $0.cpuUsage > $1.cpuUsage }
            .map { [$0.name, "\($0.pid)", $0.user, formatCPU($0.cpuUsage), formatMemory($0.memoryUsage)] }
    }

    var serviceRows: [[String]] {
        monitor.ports.map { [$0.process, $0.pid, $0.port, $0.proto] }
    }

    func formatCPU(_ value: Double) -> String {
        value < 0.05 ? "0%" : String(format: "%.1f%%", value)
    }

    func formatGPU(_ value: Double) -> String {
        value < 0.05 ? "0%" : String(format: "%.1f%%", value)
    }

    func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}

enum PerformanceResource: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case disk
    case wifi
    case gpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘 0 (C: D:)"
        case .wifi: return "Wi-Fi"
        case .gpu: return "GPU 0"
        }
    }

    var color: Color {
        switch self {
        case .cpu: return Color(red: 0.000, green: 0.510, blue: 0.690)
        case .memory: return Color(red: 0.105, green: 0.431, blue: 0.965)
        case .disk: return Color(red: 0.420, green: 0.640, blue: 0.165)
        case .wifi: return Color(red: 0.890, green: 0.090, blue: 0.340)
        case .gpu: return Color(red: 0.555, green: 0.000, blue: 1.000)
        }
    }
}

struct PerformancePage: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: ContentViewState

    var body: some View {
        let currentResource = selectedResource
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 0) {
                ForEach(Array(PerformanceResource.allCases.enumerated()), id: \.element.id) { index, resource in
                    PerformanceResourceRow(
                        resource: resource,
                        title: title(for: resource),
                        selected: currentResource == resource,
                        history: history(for: resource),
                        subtitle: subtitle(for: resource)
                    ) {
                        state.selectedPerformanceIndex = index
                    }
                }
            }
            .frame(width: 260, alignment: .topLeading)
            .padding(.top, 14)

            Group {
                switch currentResource {
                case .cpu:
                    PerformanceCPUDetail(monitor: monitor, cpuHistory: cpuHistory)
                case .memory:
                    PerformanceMemoryDetail(monitor: monitor)
                case .disk:
                    PerformanceDiskDetail(monitor: monitor)
                case .wifi:
                    PerformanceWiFiDetail(monitor: monitor)
                case .gpu:
                    PerformanceGPUDetail(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 14)
            .padding(.trailing, 22)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    private var selectedResource: PerformanceResource {
        let resources = PerformanceResource.allCases
        guard resources.indices.contains(state.selectedPerformanceIndex) else { return .cpu }
        return resources[state.selectedPerformanceIndex]
    }

    private var cpuHistory: [Double] {
        let histories = monitor.cpuCoreHistories
        guard let count = histories.map(\.count).max(), count > 0 else {
            return [monitor.totalCPU]
        }
        return (0..<count).map { index in
            let values = histories.compactMap { history -> Double? in
                index < history.count ? history[index] : nil
            }
            return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
    }

    private func history(for resource: PerformanceResource) -> [Double] {
        switch resource {
        case .cpu:
            return cpuHistory
        case .memory:
            return monitor.memoryHistory
        case .disk:
            return monitor.diskActivityHistory
        case .wifi:
            return monitor.wifiThroughputHistory.map { $0 * 100 }
        case .gpu:
            return monitor.gpuHistory
        }
    }

    private func subtitle(for resource: PerformanceResource) -> String {
        switch resource {
        case .cpu:
            return "\(monitor.hardwareInfo.cpuDisplayName)\n\(formatPercent(monitor.totalCPU))  \(monitor.hardwareInfo.cpuCoreSummary)"
        case .memory:
            return "\(monitor.hardwareInfo.memoryDisplayName)\n\(formatMemory(monitor.usedMemory))/\(formatMemory(monitor.totalMemory)) (\(formatPercent(memoryPercent)))"
        case .disk:
            return "\(monitor.hardwareInfo.diskDisplayName)\n\(formatPercent(diskPercent))"
        case .wifi:
            return "\(monitor.hardwareInfo.wifiDisplayName) · \(monitor.hardwareInfo.wifiStatus)\n发送: \(formatNetwork(monitor.networkSendBytesPerSecond)) 接收: \(formatNetwork(monitor.networkReceiveBytesPerSecond))"
        case .gpu:
            return "\(monitor.hardwareInfo.gpuDisplayName)\n\(formatPercent(monitor.totalGPU))  \(monitor.hardwareInfo.gpuCoreSummary)"
        }
    }

    private func title(for resource: PerformanceResource) -> String {
        switch resource {
        case .disk:
            return monitor.hardwareInfo.diskTitle
        default:
            return resource.title
        }
    }

    private var memoryPercent: Double {
        guard monitor.totalMemory > 0 else { return 0 }
        return Double(monitor.usedMemory) / Double(monitor.totalMemory) * 100
    }

    private var diskPercent: Double {
        min(monitor.totalDiskBytesPerSecond / (100 * 1_048_576) * 100, 100)
    }

}

struct PerformanceResourceRow: View {
    let resource: PerformanceResource
    let title: String
    let selected: Bool
    let history: [Double]
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PerformanceGraph(
                    values: normalizedHistory,
                    maxValue: 100,
                    color: resource.color,
                    fillOpacity: resource == .wifi || resource == .gpu ? 0.06 : 0.18,
                    lineWidth: 0.8
                )
                .frame(width: 74, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.black)
                        .lineLimit(1)
                    ForEach(Array(subtitleLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 0.230, green: 0.250, blue: 0.290))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(width: 260, height: 74, alignment: .leading)
            .background(selected ? Color(red: 0.965, green: 0.965, blue: 0.965) : Color.white)
            .overlay {
                Rectangle()
                    .stroke(selected ? Color.black : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var normalizedHistory: [Double] {
        history.isEmpty ? [0] : history
    }

    private var subtitleLines: [String] {
        let lines = subtitle
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(lines.prefix(2))
    }
}

struct PerformanceCPUDetail: View {
    @ObservedObject var monitor: SystemMonitor
    let cpuHistory: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PerformanceDetailHeader(title: "CPU", deviceName: monitor.hardwareInfo.cpuDisplayName)
            HStack {
                Text("60 秒内的利用率 %")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                Spacer()
                Text("100%")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(0..<cpuGraphCount, id: \.self) { index in
                    PerformanceGraph(
                        values: cpuCoreHistory(index),
                        maxValue: 100,
                        color: PerformanceResource.cpu.color,
                        fillOpacity: 0.20,
                        lineWidth: 0.75
                    )
                    .frame(height: cpuGraphHeight)
                }
            }

            HStack(alignment: .top, spacing: 42) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 26) {
                        PerformanceLargeMetric(label: "利用率", value: formatPercent(monitor.totalCPU))
                        PerformanceLargeMetric(label: "基准速度", value: monitor.hardwareInfo.cpuBaseSpeed)
                    }
                    HStack(alignment: .top, spacing: 30) {
                        PerformanceLargeMetric(label: "进程", value: "\(monitor.processes.count)")
                        PerformanceLargeMetric(label: "线程", value: "\(max(monitor.processes.count * 12, 0))")
                        PerformanceLargeMetric(label: "句柄", value: "\(monitor.processes.count * 73)")
                    }
                    PerformanceLargeMetric(label: "正常运行时间", value: uptimeText)
                }

                VStack(alignment: .leading, spacing: 6) {
                    PerformanceKeyValue(label: "芯片:", value: monitor.hardwareInfo.cpuDisplayName)
                    PerformanceKeyValue(label: "插槽:", value: "1")
                    PerformanceKeyValue(label: "内核:", value: monitor.hardwareInfo.physicalCPUCount > 0 ? "\(monitor.hardwareInfo.physicalCPUCount)" : "未知")
                    PerformanceKeyValue(label: "逻辑处理器:", value: monitor.hardwareInfo.logicalCPUCount > 0 ? "\(monitor.hardwareInfo.logicalCPUCount)" : "未知")
                    PerformanceKeyValue(label: "虚拟化:", value: "已启用")
                    PerformanceKeyValue(label: "L1 缓存:", value: monitor.hardwareInfo.cpuL1Cache)
                    PerformanceKeyValue(label: "L2 缓存:", value: monitor.hardwareInfo.cpuL2Cache)
                    PerformanceKeyValue(label: "L3 缓存:", value: monitor.hardwareInfo.cpuL3Cache)
                }
            }
            .padding(.top, 22)
        }
    }

    private func cpuCoreHistory(_ index: Int) -> [Double] {
        if index < monitor.cpuCoreHistories.count, !monitor.cpuCoreHistories[index].isEmpty {
            return monitor.cpuCoreHistories[index]
        }
        return cpuHistory.isEmpty ? [0] : cpuHistory
    }

    private var cpuGraphCount: Int {
        max(monitor.cpuCoreHistories.count, monitor.hardwareInfo.logicalCPUCount, 1)
    }

    private var cpuGraphHeight: CGFloat {
        cpuGraphCount > 8 ? 68 : 86
    }

}

struct PerformanceMemoryDetail: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PerformanceDetailHeader(title: "内存", deviceName: monitor.hardwareInfo.memoryDisplayName)
            Text("内存使用量")
                .font(.system(size: 12))
                .foregroundColor(TaskManagerStyle.muted)
            PerformanceGraph(values: monitor.memoryHistory, maxValue: 100, color: PerformanceResource.memory.color, fillOpacity: 0.18, lineWidth: 0.8)
                .frame(height: 280)
            HStack {
                Text("60 秒")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                Spacer()
                Text("0")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
            }
            Text("内存组合")
                .font(.system(size: 12))
                .foregroundColor(TaskManagerStyle.muted)
                .padding(.top, 4)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white)
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.75), lineWidth: 1))
                Rectangle()
                    .fill(PerformanceResource.memory.color.opacity(0.18))
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: memoryPercent / 100, y: 1, anchor: .leading)
            }
            .frame(height: 42)

            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 36) {
                        PerformanceLargeMetric(label: "使用中", value: formatMemory(monitor.usedMemory))
                        PerformanceLargeMetric(label: "可用", value: formatMemory(monitor.totalMemory > monitor.usedMemory ? monitor.totalMemory - monitor.usedMemory : 0))
                    }
                    HStack(spacing: 36) {
                        PerformanceLargeMetric(label: "已提交", value: "\(formatMemory(monitor.usedMemory))/\(formatMemory(monitor.totalMemory))")
                        PerformanceLargeMetric(label: "已缓存", value: formatMemory(monitor.usedMemory / 3))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    PerformanceKeyValue(label: "类型:", value: monitor.hardwareInfo.memoryType)
                    PerformanceKeyValue(label: "生产企业:", value: monitor.hardwareInfo.memoryManufacturer)
                    PerformanceKeyValue(label: "总容量:", value: monitor.hardwareInfo.memoryCapacity)
                    PerformanceKeyValue(label: "已使用的插槽:", value: "不可用")
                    PerformanceKeyValue(label: "外形规格:", value: "统一内存")
                    PerformanceKeyValue(label: "为硬件保留的内存:", value: "0 MB")
                }
            }
            .padding(.top, 14)
        }
    }

    private var memoryPercent: Double {
        guard monitor.totalMemory > 0 else { return 0 }
        return Double(monitor.usedMemory) / Double(monitor.totalMemory) * 100
    }
}

struct PerformanceDiskDetail: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PerformanceDetailHeader(title: monitor.hardwareInfo.diskTitle, deviceName: monitor.hardwareInfo.diskDisplayName)
            HStack {
                Text("活动时间")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                Spacer()
                Text("100%")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
            }
            PerformanceGraph(values: monitor.diskActivityHistory, maxValue: 100, color: PerformanceResource.disk.color, fillOpacity: 0.18, lineWidth: 0.75)
                .frame(height: 220)
            GraphTimeLabels()

            HStack {
                Text("磁盘传输速率")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                Spacer()
                Text("100 MB/秒")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
            }
            PerformanceGraph(values: monitor.diskTransferHistory, maxValue: 100, color: PerformanceResource.disk.color, fillOpacity: 0.10, lineWidth: 0.75, middleLabel: "60 MB/秒")
                .frame(height: 82)
            GraphTimeLabels()

            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 30) {
                        PerformanceLargeMetric(label: "活动时间", value: formatPercent(diskPercent))
                        PerformanceLargeMetric(label: "平均响应时间", value: "64.4 毫秒")
                    }
                    HStack(spacing: 32) {
                        PerformanceAccentMetric(label: "读取速度", value: formatBytes(monitor.diskReadBytesPerSecond), color: PerformanceResource.disk.color)
                        PerformanceAccentMetric(label: "写入速度", value: formatBytes(monitor.diskWriteBytesPerSecond), color: PerformanceResource.disk.color, dashed: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    PerformanceKeyValue(label: "容量:", value: monitor.hardwareInfo.diskCapacity)
                    PerformanceKeyValue(label: "文件系统:", value: monitor.hardwareInfo.diskFileSystem)
                    PerformanceKeyValue(label: "系统磁盘:", value: "是")
                    PerformanceKeyValue(label: "内部磁盘:", value: monitor.hardwareInfo.diskInternal)
                    PerformanceKeyValue(label: "类型:", value: "\(monitor.hardwareInfo.diskMediumType) · \(monitor.hardwareInfo.diskProtocol)")
                }
            }
            .padding(.top, 10)
        }
    }

    private var diskPercent: Double {
        min(monitor.totalDiskBytesPerSecond / (100 * 1_048_576) * 100, 100)
    }
}

struct PerformanceWiFiDetail: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PerformanceDetailHeader(title: "Wi-Fi", deviceName: monitor.hardwareInfo.wifiDisplayName)
            HStack {
                Text("吞吐量")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                Spacer()
                Text("1 Mbps")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
            }
            PerformanceGraph(values: monitor.wifiThroughputHistory, maxValue: 1, color: PerformanceResource.wifi.color, fillOpacity: 0.10, lineWidth: 0.75, middleLabel: "800 Kbps")
                .frame(height: 335)
            GraphTimeLabels()

            HStack(alignment: .top, spacing: 60) {
                VStack(alignment: .leading, spacing: 14) {
                    PerformanceAccentMetric(label: "发送", value: formatNetwork(monitor.networkSendBytesPerSecond), color: PerformanceResource.wifi.color)
                    PerformanceAccentMetric(label: "接收", value: formatNetwork(monitor.networkReceiveBytesPerSecond), color: PerformanceResource.wifi.color)
                }
                VStack(alignment: .leading, spacing: 6) {
                    PerformanceKeyValue(label: "接口:", value: monitor.hardwareInfo.wifiInterface)
                    PerformanceKeyValue(label: "SSID:", value: monitor.hardwareInfo.wifiSSID)
                    PerformanceKeyValue(label: "支持模式:", value: monitor.hardwareInfo.wifiConnectionType)
                    PerformanceKeyValue(label: "IPv4 地址:", value: monitor.hardwareInfo.wifiIPv4)
                    PerformanceKeyValue(label: "状态:", value: monitor.hardwareInfo.wifiStatus)
                    HStack(spacing: 10) {
                        Text("信号强度:")
                            .font(.system(size: 12))
                            .foregroundColor(TaskManagerStyle.muted)
                            .frame(width: 74, alignment: .leading)
                        SignalBars(color: Color(red: 0.760, green: 0.520, blue: 0.360))
                    }
                }
            }
            .padding(.top, 10)
        }
    }
}

struct PerformanceGPUDetail: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PerformanceDetailHeader(title: "GPU", deviceName: monitor.hardwareInfo.gpuDisplayName)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 8) {
                ForEach(["3D", "Copy", "Video Decode", "Video Processing"], id: \.self) { title in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("⌄ \(title)")
                                .font(.system(size: 12))
                                .foregroundColor(TaskManagerStyle.muted)
                            Spacer()
                            Text(formatPercent(title == "3D" ? monitor.totalGPU : 0))
                                .font(.system(size: 12))
                                .foregroundColor(TaskManagerStyle.muted)
                        }
                        PerformanceGraph(values: title == "3D" ? monitor.gpuHistory : [0], maxValue: 100, color: PerformanceResource.gpu.color, fillOpacity: 0.05, lineWidth: 0.75)
                            .frame(height: 96)
                    }
                }
            }

            HStack {
                Text("统一内存")
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
                Spacer()
                Text(monitor.hardwareInfo.memoryCapacity)
                    .font(.system(size: 12))
                    .foregroundColor(TaskManagerStyle.muted)
            }
            .padding(.top, 6)
            PerformanceGraph(values: monitor.gpuHistory, maxValue: 100, color: PerformanceResource.gpu.color, fillOpacity: 0.04, lineWidth: 0.75)
                .frame(height: 78)

            HStack(alignment: .top, spacing: 42) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 48) {
                        PerformanceLargeMetric(label: "利用率", value: formatPercent(monitor.totalGPU))
                        PerformanceLargeMetric(label: "统一内存", value: monitor.hardwareInfo.memoryCapacity)
                    }
                    PerformanceLargeMetric(label: "核心", value: monitor.hardwareInfo.gpuCoreSummary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    PerformanceKeyValue(label: "芯片型号:", value: monitor.hardwareInfo.gpuDisplayName)
                    PerformanceKeyValue(label: "类型:", value: monitor.hardwareInfo.gpuType)
                    PerformanceKeyValue(label: "总线:", value: monitor.hardwareInfo.gpuBus)
                    PerformanceKeyValue(label: "供应商:", value: monitor.hardwareInfo.gpuVendor)
                    PerformanceKeyValue(label: "Metal 支持:", value: monitor.hardwareInfo.gpuMetalSupport)
                }
            }
            .padding(.top, 10)
        }
    }
}

struct PerformanceDetailHeader: View {
    let title: String
    let deviceName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 30, weight: .regular))
                .foregroundColor(.black)
            Spacer()
            Text(deviceName)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.black)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

struct PerformanceGraph: View {
    let values: [Double]
    let maxValue: Double
    let color: Color
    let fillOpacity: Double
    let lineWidth: CGFloat
    var middleLabel: String? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = graphPoints(in: size)
            ZStack {
                PerformanceGrid()
                if points.count > 1 {
                    fillPath(points: points, size: size)
                        .fill(color.opacity(fillOpacity))
                    linePath(points: points)
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                }
                if let middleLabel {
                    Text(middleLabel)
                        .font(.system(size: 11))
                        .foregroundColor(TaskManagerStyle.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 2)
                }
            }
        }
        .background(Color.white)
        .overlay {
            Rectangle()
                .stroke(Color(red: 0.520, green: 0.520, blue: 0.520), lineWidth: 0.7)
        }
    }

    private func graphPoints(in size: CGSize) -> [CGPoint] {
        let safeMax = max(maxValue, 0.001)
        let source = values.suffix(30)
        let paddingCount = max(30 - source.count, 0)
        let padded = Array(repeating: Double(0), count: paddingCount) + source
        return padded.enumerated().map { index, value in
            let x = CGFloat(index) / CGFloat(max(padded.count - 1, 1)) * size.width
            let normalized = min(max(value / safeMax, 0), 1)
            let y = size.height - CGFloat(normalized) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func fillPath(points: [CGPoint], size: CGSize) -> Path {
        var path = linePath(points: points)
        if let last = points.last, let first = points.first {
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

struct PerformanceGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let width = proxy.size.width
                let height = proxy.size.height
                for index in 1..<12 {
                    let x = width * CGFloat(index) / 12
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                }
                for index in 1..<8 {
                    let y = height * CGFloat(index) / 8
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(Color(red: 0.900, green: 0.900, blue: 0.900), lineWidth: 0.55)
        }
    }
}

struct GraphTimeLabels: View {
    var body: some View {
        HStack {
            Text("60 秒")
            Spacer()
            Text("0")
        }
        .font(.system(size: 12))
        .foregroundColor(TaskManagerStyle.muted)
    }
}

struct PerformanceLargeMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(TaskManagerStyle.muted)
            Text(value)
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.black)
                .lineLimit(1)
        }
    }
}

struct PerformanceAccentMetric: View {
    let label: String
    let value: String
    let color: Color
    var dashed = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(dashed ? Color.clear : color)
                .frame(width: 1.4)
                .overlay {
                    if dashed {
                        DashedVerticalLine(color: color)
                    }
                }
            PerformanceLargeMetric(label: label, value: value)
        }
        .frame(height: 42)
    }
}

struct DashedVerticalLine: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
        }
    }
}

struct PerformanceKeyValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(TaskManagerStyle.muted)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.black)
                .lineLimit(1)
        }
    }
}

struct SignalBars: View {
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(index < 4 ? 1 : 0.35))
                    .frame(width: 3, height: CGFloat(index + 1) * 4)
            }
        }
        .frame(height: 24, alignment: .bottom)
    }
}

private func formatPercent(_ value: Double) -> String {
    value < 0.05 ? "0%" : String(format: "%.0f%%", value)
}

private func formatMemory(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 {
        return String(format: "%.1f GB", gb)
    }
    return String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

private func formatBytes(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_048_576 {
        return String(format: "%.1f MB/秒", bytesPerSecond / 1_048_576)
    }
    return String(format: "%.1f KB/秒", bytesPerSecond / 1024)
}

private func formatNetwork(_ bytesPerSecond: Double) -> String {
    let kbps = bytesPerSecond * 8 / 1_000
    if kbps >= 1000 {
        return String(format: "%.1f Mbps", kbps / 1000)
    }
    return String(format: "%.0f Kbps", kbps)
}

private var uptimeText: String {
    var bootTime = timeval()
    var size = MemoryLayout<timeval>.stride
    sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
    let bootDate = Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
    let interval = max(Date().timeIntervalSince(bootDate), 0)
    let days = Int(interval) / 86_400
    let hours = (Int(interval) % 86_400) / 3_600
    let minutes = (Int(interval) % 3_600) / 60
    let seconds = Int(interval) % 60
    return String(format: "%d:%02d:%02d:%02d", days, hours, minutes, seconds)
}

struct MetricSummaryRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(TaskManagerStyle.text)
            Spacer()
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.black)
        }
        .padding(.horizontal, 16)
        .frame(width: 260, height: 54)
        .background(TaskManagerStyle.resource.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct SimpleDataTable: View {
    let columns: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(columns, id: \.self) { column in
                        Text(column)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(TaskManagerStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .overlay(alignment: .trailing) {
                                VerticalRule()
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(TaskManagerStyle.grid)
                        .frame(height: 1)
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .font(.system(size: 14))
                                .foregroundColor(.black)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .overlay(alignment: .trailing) {
                                    VerticalRule()
                                }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .background(Color.white)
    }
}

struct TaskManagerProcessTable: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: ContentViewState

    let nameWidth: CGFloat = 292
    let actionWidth: CGFloat = 150
    let metricWidth: CGFloat = 91

    var memoryPercent: Double {
        guard monitor.totalMemory > 0 else { return 0 }
        return Double(monitor.usedMemory) / Double(monitor.totalMemory) * 100
    }

    var diskPercent: Double {
        let bytesPerSecond = monitor.processes.reduce(0) { $0 + $1.diskBytesPerSecond }
        return min(bytesPerSecond / (100 * 1_048_576) * 100, 99)
    }

    var networkPercent: Double {
        let bytesPerSecond = monitor.processes.reduce(0) { $0 + $1.networkBytesPerSecond }
        return min(bytesPerSecond / 125_000_000 * 100, 99)
    }

    var body: some View {
        let tableData = state.processTableData(
            processes: monitor.processes,
            processVersion: monitor.processVersion
        )

        VStack(alignment: .leading, spacing: 0) {
            TableHeader(
                nameWidth: nameWidth,
                actionWidth: actionWidth,
                metricWidth: metricWidth,
                cpu: monitor.totalCPU,
                gpu: monitor.totalGPU,
                memory: memoryPercent,
                disk: diskPercent,
                network: networkPercent
            )

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ProcessGroupHeader(title: "应用", count: tableData.appRootProcesses.count, nameWidth: nameWidth, actionWidth: actionWidth, metricWidth: metricWidth)

                    ForEach(tableData.appProcessRows) { row in
                        ProcessTableRow(
                            process: row.process,
                            level: row.level,
                            hasChildren: row.hasChildren,
                            childCount: row.childCount,
                            isExpanded: row.isExpanded,
                            selected: state.selectedPID == row.process.pid,
                            nameWidth: nameWidth,
                            actionWidth: actionWidth,
                            metricWidth: metricWidth,
                            sample: resourceSample(for: row.resources),
                            onToggleExpanded: {
                                toggleExpanded(row.process.pid)
                            },
                            onKillProcess: {
                                monitor.killProcess(pid: row.process.pid, name: row.process.name)
                            }
                        )
                        .onTapGesture {
                            state.selectedPID = row.process.pid
                        }
                        .onHover { hovering in
                            if hovering, state.selectedPID != row.process.pid {
                                state.selectedPID = row.process.pid
                            }
                        }
                    }

                    ProcessGroupHeader(title: "后台进程", count: tableData.backgroundRootProcesses.count, nameWidth: nameWidth, actionWidth: actionWidth, metricWidth: metricWidth)

                    ForEach(tableData.backgroundProcessRows) { row in
                        ProcessTableRow(
                            process: row.process,
                            level: row.level,
                            hasChildren: row.hasChildren,
                            childCount: row.childCount,
                            isExpanded: row.isExpanded,
                            selected: state.selectedPID == row.process.pid,
                            nameWidth: nameWidth,
                            actionWidth: actionWidth,
                            metricWidth: metricWidth,
                            sample: resourceSample(for: row.resources),
                            onToggleExpanded: {
                                toggleExpanded(row.process.pid)
                            },
                            onKillProcess: {
                                monitor.killProcess(pid: row.process.pid, name: row.process.name)
                            }
                        )
                        .onTapGesture {
                            state.selectedPID = row.process.pid
                        }
                        .onHover { hovering in
                            if hovering, state.selectedPID != row.process.pid {
                                state.selectedPID = row.process.pid
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
                .frame(width: nameWidth + actionWidth + metricWidth * 5, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .onHover { hovering in
                if hovering {
                    if state.frozenProcessOrder == nil {
                        state.frozenProcessOrder = tableData.filteredProcesses.map(\.pid)
                    }
                } else {
                    state.frozenProcessOrder = nil
                }
            }
        }
        .background(Color.white)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TaskManagerStyle.grid)
                .frame(height: 1)
                .offset(y: 63)
        }
    }

    func resourceSample(for resources: ProcessResourceValues) -> ResourceSample {
        ResourceSample(
            cpuUsage: resources.cpuUsage,
            gpuUsage: resources.gpuUsage,
            memoryUsage: resources.memoryUsage,
            diskBytesPerSecond: resources.diskBytesPerSecond,
            networkBytesPerSecond: resources.networkBytesPerSecond
        )
    }

    func toggleExpanded(_ pid: Int32) {
        if state.expandedProcessIDs.contains(pid) {
            state.expandedProcessIDs.remove(pid)
        } else {
            state.expandedProcessIDs.insert(pid)
        }
    }
}

struct TableHeader: View {
    let nameWidth: CGFloat
    let actionWidth: CGFloat
    let metricWidth: CGFloat
    let cpu: Double
    let gpu: Double
    let memory: Double
    let disk: Double
    let network: Double

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .offset(x: -15, y: -8)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("名称")
                    .font(.system(size: 14))
                    .foregroundColor(TaskManagerStyle.muted)
                    .offset(y: -7)
            }
            .padding(.leading, 18)
            .frame(width: nameWidth, height: 64, alignment: .bottomLeading)
            .background(TaskManagerStyle.headerCell)
            .overlay(alignment: .trailing) {
                VerticalRule()
            }

            Text("操作")
                .font(.system(size: 14))
                .foregroundColor(TaskManagerStyle.muted)
                .offset(y: -7)
                .padding(.leading, 8)
                .frame(width: actionWidth, height: 64, alignment: .bottomLeading)
                .background(TaskManagerStyle.headerCell)
                .overlay(alignment: .trailing) {
                    VerticalRule()
                }

            MetricHeader(value: String(format: "%.0f%%", cpu), title: "CPU", width: metricWidth)
            MetricHeader(value: String(format: "%.0f%%", gpu), title: "GPU", width: metricWidth)
            MetricHeader(value: String(format: "%.0f%%", memory), title: "内存", width: metricWidth)
            MetricHeader(value: String(format: "%.0f%%", disk), title: "磁盘", width: metricWidth)
            MetricHeader(value: String(format: "%.0f%%", network), title: "网络", width: metricWidth)
        }
        .frame(height: 64)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TaskManagerStyle.grid)
                .frame(height: 1)
        }
    }
}

struct MetricHeader: View {
    let value: String
    let title: String
    let width: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.black)
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(TaskManagerStyle.muted)
        }
        .frame(width: width, height: 64, alignment: .center)
        .overlay(alignment: .trailing) {
            VerticalRule()
        }
    }
}

struct ProcessGroupHeader: View {
    let title: String
    let count: Int
    let nameWidth: CGFloat
    let actionWidth: CGFloat
    let metricWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("\(title) (\(count))")
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.black)
                .offset(y: 4)
                .padding(.leading, 22)
                .frame(width: nameWidth, height: 48, alignment: .leading)
                .overlay(alignment: .trailing) {
                    VerticalRule()
                }

            Color.white
                .frame(width: actionWidth, height: 48)
                .overlay(alignment: .trailing) {
                    VerticalRule()
                }

            ForEach(0..<5, id: \.self) { _ in
                Color.white
                    .frame(width: metricWidth, height: 48)
                    .overlay(alignment: .trailing) {
                        VerticalRule()
                    }
            }
        }
        .background(Color.white)
    }
}

struct ProcessTableRow: View {
    let process: AppProcess
    let level: Int
    let hasChildren: Bool
    let childCount: Int
    let isExpanded: Bool
    let selected: Bool
    let nameWidth: CGFloat
    let actionWidth: CGFloat
    let metricWidth: CGFloat
    let sample: ResourceSample
    let onToggleExpanded: () -> Void
    let onKillProcess: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if hasChildren {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gray)
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            TapGesture().onEnded {
                                onToggleExpanded()
                            }
                        )
                } else {
                    Color.clear
                        .frame(width: 16, height: 24)
                }

                if let icon = process.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app")
                        .font(.system(size: 17))
                        .foregroundColor(.blue)
                        .frame(width: 18, height: 18)
                }

                Text(rowTitle)
                    .font(.system(size: 15))
                    .foregroundColor(.black)
                    .lineLimit(1)
            }
            .offset(y: 2)
            .padding(.leading, 22 + CGFloat(level) * 22)
            .frame(width: nameWidth, height: 34, alignment: .leading)
            .background(selected ? TaskManagerStyle.selectedRow : Color.white)
            .overlay(alignment: .trailing) {
                VerticalRule()
            }

            KillProcessButton(action: onKillProcess)
                .frame(width: actionWidth, height: 34)
            .background(selected ? TaskManagerStyle.selectedRow : Color.white)
            .overlay(alignment: .trailing) {
                VerticalRule()
            }

            ResourceCell(text: formatCPU(sample.cpuUsage), width: metricWidth, intensity: min(sample.cpuUsage / 12, 1))
            ResourceCell(text: formatGPU(sample.gpuUsage), width: metricWidth, intensity: min(sample.gpuUsage / 40, 1))
            ResourceCell(text: formatMemory(sample.memoryUsage), width: metricWidth, intensity: memoryIntensity(sample.memoryUsage))
            ResourceCell(text: formatDisk(sample.diskBytesPerSecond), width: metricWidth, intensity: diskIntensity(sample.diskBytesPerSecond))
            ResourceCell(text: formatNetwork(sample.networkBytesPerSecond), width: metricWidth, intensity: networkIntensity(sample.networkBytesPerSecond))
        }
        .contentShape(Rectangle())
    }

    var rowTitle: String {
        let name = displayName(for: process)
        return hasChildren ? "\(name) (\(childCount))" : name
    }

    func displayName(for process: AppProcess) -> String {
        if process.isApp {
            return process.name
        }
        return process.name.isEmpty ? "进程 \(process.pid)" : process.name
    }

    func formatCPU(_ value: Double) -> String {
        value < 0.05 ? "0%" : String(format: "%.1f%%", value)
    }

    func formatGPU(_ value: Double) -> String {
        value < 0.05 ? "0%" : String(format: "%.1f%%", value)
    }

    func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }

    func memoryIntensity(_ bytes: UInt64) -> Double {
        let mb = Double(bytes) / 1_048_576
        return min(mb / 900, 1)
    }

    func diskIntensity(_ bytesPerSecond: Double) -> Double {
        min(bytesPerSecond / 1_048_576, 1)
    }

    func networkIntensity(_ bytesPerSecond: Double) -> Double {
        min(bytesPerSecond / 125_000, 1)
    }

    func formatDisk(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_048_576
        return mb < 0.05 ? "0 MB/秒" : String(format: "%.1f MB/秒", mb)
    }

    func formatNetwork(_ bytesPerSecond: Double) -> String {
        let mbps = bytesPerSecond * 8 / 1_000_000
        return mbps < 0.05 ? "0 Mbps" : String(format: "%.1f Mbps", mbps)
    }
}

struct KillProcessButton: View {
    let action: () -> Void
    @StateObject private var hover = KillProcessButtonHoverState()

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "nosign")
                        .font(.system(size: 15, weight: .medium))
                    Text("结束任务")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(TaskManagerStyle.text)
                .frame(width: 96, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hover.isHovered ? Color(red: 0.945, green: 0.945, blue: 0.945) : Color.clear)
                }
            }
            .buttonStyle(.plain)
            .help("结束进程")
            .onHover { hovering in
                hover.isHovered = hovering
            }
            Spacer()
        }
    }
}

final class KillProcessButtonHoverState: ObservableObject {
    @Published var isHovered = false
}

struct ResourceCell: View {
    let text: String
    let width: CGFloat
    let intensity: Double

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundColor(.black)
            .lineLimit(1)
            .offset(y: 2)
            .frame(width: width - 14, height: 34, alignment: .trailing)
            .padding(.trailing, 14)
            .background(resourceColor)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(resourceRuleColor)
                    .frame(width: 1)
            }
    }

    var resourceColor: Color {
        let amount = min(max(intensity, 0), 1)
        return Color(
            red: 0.839 - 0.227 * amount,
            green: 0.945 - 0.078 * amount,
            blue: 1.000
        )
    }

    var resourceRuleColor: Color {
        Color(red: 0.700, green: 0.843, blue: 0.914)
    }
}

struct VerticalRule: View {
    var body: some View {
        Rectangle()
            .fill(TaskManagerStyle.grid)
            .frame(width: 1)
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.configureWindows()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureWindows() {
        for window in NSApp.windows {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask = [.borderless, .resizable, .miniaturizable]
            window.hasShadow = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            window.contentView?.superview?.wantsLayer = true
            window.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
            window.contentViewController?.view.wantsLayer = true
            window.contentViewController?.view.layer?.backgroundColor = NSColor.clear.cgColor
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.minSize = NSSize(
                width: TaskManagerStyle.minContentWidth + TaskManagerStyle.shadowMargin * 2,
                height: TaskManagerStyle.minContentHeight + TaskManagerStyle.shadowMargin * 2
            )
            window.setContentSize(NSSize(
                width: TaskManagerStyle.contentWidth + TaskManagerStyle.shadowMargin * 2,
                height: TaskManagerStyle.contentHeight + TaskManagerStyle.shadowMargin * 2
            ))
            window.invalidateShadow()
        }
    }
}

@main
struct MacSystemMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("系统监视器") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: TaskManagerStyle.contentWidth + TaskManagerStyle.shadowMargin * 2,
            height: TaskManagerStyle.contentHeight + TaskManagerStyle.shadowMargin * 2
        )
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
