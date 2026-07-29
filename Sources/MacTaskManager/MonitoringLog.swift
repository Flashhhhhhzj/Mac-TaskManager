import AppKit
import Combine
import Foundation
import MacSMC
import UniformTypeIdentifiers

enum MonitoringLogPreferences {
    static let persistenceEnabledKey = "MonitoringLogPersistenceEnabled"
    static let retentionInterval: TimeInterval = 60 * 60
    static let maximumStorageBytes: Int64 = 256 * 1_024 * 1_024

    static var isPersistenceEnabled: Bool {
        UserDefaults.standard.bool(forKey: persistenceEnabledKey)
    }

    static func setPersistenceEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: persistenceEnabledKey)
    }
}

enum MonitoringLogExportError: LocalizedError, Equatable {
    case noDestination
    case unableToCreateArchive

    var errorDescription: String? {
        switch self {
        case .noDestination:
            return "没有选择日志导出位置。"
        case .unableToCreateArchive:
            return "无法创建系统运行日志归档。"
        }
    }
}

final class MonitoringLogRecorder: ObservableObject {
    @Published private(set) var isPersistenceEnabled: Bool
    @Published private(set) var isExporting = false
    @Published private(set) var exportErrorMessage: String?

    private let journal: MonitoringLogJournal
    private var latestSystemSnapshot: MonitoringSystemLogSnapshot?
    private var latestFanSnapshot: MonitoringFanLogSnapshot?
    private var latestCoolModeDecision: MonitoringCoolModeDecision?

    init() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "Mac-TaskManager"
        journal = MonitoringLogJournal(bundleIdentifier: bundleIdentifier)
        isPersistenceEnabled = MonitoringLogPreferences.isPersistenceEnabled
        if isPersistenceEnabled {
            journal.startRecording()
        }
    }

    var persistenceDescription: String {
        isPersistenceEnabled
            ? "已开启：本地保存最近 60 分钟的监控、风扇与清凉模式决策日志"
            : "默认关闭。关闭后不保存历史日志，并清除已保存的本地历史"
    }

    func setPersistenceEnabled(_ enabled: Bool) {
        guard isPersistenceEnabled != enabled else { return }
        MonitoringLogPreferences.setPersistenceEnabled(enabled)
        isPersistenceEnabled = enabled

        if enabled {
            journal.startRecording()
        } else {
            journal.stopAndDelete()
        }
    }

    func recordSystemSnapshot(_ snapshot: MonitoringSystemLogSnapshot) {
        latestSystemSnapshot = snapshot
        guard isPersistenceEnabled else { return }
        journal.append(snapshot, category: .system)
    }

    func recordFanSnapshot(_ snapshot: MonitoringFanLogSnapshot) {
        latestFanSnapshot = snapshot
        guard isPersistenceEnabled else { return }
        journal.append(snapshot, category: .fans)
    }

    func recordCoolModeDecision(_ decision: MonitoringCoolModeDecision) {
        latestCoolModeDecision = decision
        guard isPersistenceEnabled else { return }
        journal.append(decision, category: .coolMode)
    }

    func exportArchive(completion: @escaping (Result<URL, Error>) -> Void) {
        let savePanel = NSSavePanel()
        savePanel.title = "导出系统运行日志"
        savePanel.message = "日志仅保存到你选择的位置，不会上传网络。"
        savePanel.nameFieldStringValue = "MacTaskManager-SystemLog-\(Self.exportFileTimestamp()).zip"
        savePanel.allowedContentTypes = [.zip]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
            completion(.failure(MonitoringLogExportError.noDestination))
            return
        }

        let systemSnapshot = latestSystemSnapshot
        let fanSnapshot = latestFanSnapshot
        let coolModeDecision = latestCoolModeDecision
        let persistenceEnabled = isPersistenceEnabled
        isExporting = true

        DispatchQueue.global(qos: .userInitiated).async { [journal] in
            let result: Result<URL, Error>
            do {
                let fileManager = FileManager.default
                let exportDirectory = fileManager.temporaryDirectory
                    .appendingPathComponent("MacTaskManager-SystemLog-\(UUID().uuidString)", isDirectory: true)
                defer { try? fileManager.removeItem(at: exportDirectory) }

                try fileManager.createDirectory(
                    at: exportDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )

                let coverage = try journal.copyRetainedSegments(to: exportDirectory)
                let currentSnapshot = MonitoringLogCurrentSnapshot(
                    exportedAt: Date(),
                    system: systemSnapshot,
                    fans: fanSnapshot,
                    latestCoolModeDecision: coolModeDecision
                )
                try Self.writeJSON(currentSnapshot, named: "current-snapshot.json", in: exportDirectory)

                let manifest = MonitoringLogManifest(
                    schemaVersion: 1,
                    applicationName: "Mac-TaskManager",
                    exportedAt: Date(),
                    recordingWasEnabled: persistenceEnabled,
                    samplingIntervalSeconds: 2,
                    retentionIntervalSeconds: MonitoringLogPreferences.retentionInterval,
                    maximumStorageBytes: MonitoringLogPreferences.maximumStorageBytes,
                    historicalCoverageStart: coverage.start,
                    historicalCoverageEnd: coverage.end,
                    containsHistoricalRecords: coverage.segmentCount > 0,
                    includedFiles: coverage.includedFiles
                )
                try Self.writeJSON(manifest, named: "manifest.json", in: exportDirectory)

                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try Self.createZIPArchive(from: exportDirectory, to: destinationURL)
                result = .success(destinationURL)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.isExporting = false
                completion(result)
            }
        }
    }

    func shutdown() {
        journal.flush()
    }

    func presentExportError(_ message: String) {
        exportErrorMessage = message
    }

    func clearExportError() {
        exportErrorMessage = nil
    }

    private static func writeJSON<T: Encodable>(
        _ value: T,
        named fileName: String,
        in directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    private static func createZIPArchive(from sourceURL: URL, to destinationURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            sourceURL.path,
            destinationURL.path
        ]
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw MonitoringLogExportError.unableToCreateArchive
        }
    }

    private static func exportFileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

struct MonitoringSystemLogSnapshot: Codable {
    let timestamp: Date
    let cpu: MonitoringCPULog
    let gpuUsage: Double
    let memory: MonitoringMemoryLog
    let disk: MonitoringDiskLog
    let network: MonitoringNetworkLog
    let processes: [MonitoringProcessLog]
    let ports: [MonitoringPortLog]
    let hardware: MonitoringHardwareLog
}

struct MonitoringCPULog: Codable {
    let totalUsage: Double
    let cores: [MonitoringCPUCoreLog]
}

struct MonitoringCPUCoreLog: Codable {
    let index: Int
    let usage: Double
}

struct MonitoringMemoryLog: Codable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let usagePercent: Double
}

struct MonitoringDiskLog: Codable {
    let totalBytesPerSecond: Double
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

struct MonitoringNetworkLog: Codable {
    let totalBytesPerSecond: Double
    let receiveBytesPerSecond: Double
    let sendBytesPerSecond: Double
}

struct MonitoringProcessLog: Codable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let user: String
    let isApplication: Bool
    let status: String
    let runningSeconds: Double?
    let cpuUsage: Double
    let gpuUsage: Double
    let memoryUsageBytes: UInt64
    let diskBytesPerSecond: Double
    let networkBytesPerSecond: Double
}

struct MonitoringPortLog: Codable {
    let port: String
    let process: String
    let pid: String
    let protocolName: String
}

struct MonitoringHardwareLog: Codable {
    let cpuName: String
    let cpuDisplayName: String
    let physicalCPUCount: Int
    let logicalCPUCount: Int
    let memoryCapacity: String
    let diskName: String
    let diskCapacity: String
    let wifiInterface: String
    let wifiSSID: String
    let gpuName: String
    let gpuDisplayName: String
}

struct MonitoringFanLogSnapshot: Codable {
    let timestamp: Date
    let hardwareModel: String
    let helperAuthorizationState: String
    let coolModeState: String
    let coolModePolicy: String
    let coolModeTargets: [String: Double]
    let fans: [MonitoringFanLog]
    let temperatures: [MonitoringTemperatureLog]
}

struct MonitoringFanLog: Codable {
    let index: Int
    let actualRPM: Double
    let targetRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let isManual: Bool
}

struct MonitoringTemperatureLog: Codable {
    let key: String
    let name: String
    let group: String
    let celsius: Double
}

struct MonitoringCoolModeInputLog: Codable {
    let cpuUsage: Double
    let gpuUsage: Double
    let memoryUsage: Double
    let diskBytesPerSecond: Double
    let cpuTemperature: Double?
    let gpuTemperature: Double?
    let systemTemperature: Double?
}

struct MonitoringCoolModeAssessmentLog: Codable {
    let heatLevel: String
    let predictedHeatScore: Double
    let workloadScore: Double
    let temperatureScore: Double
    let risingBonus: Double
    let requestedCoolingDemand: Double
    let coolingDemand: Double
    let previousCoolingDemand: Double?
    let smoothingAction: String
    let dominantFactor: String
    let highestTemperature: Double
    let temperatureRise: Double
}

struct MonitoringCoolModeDecision: Codable {
    let timestamp: Date
    let event: String
    let state: String
    let policy: String
    let helperAuthorizationState: String
    let input: MonitoringCoolModeInputLog?
    let assessment: MonitoringCoolModeAssessmentLog?
    let targetRPMs: [String: Double]
    let fans: [MonitoringFanLog]
    let message: String?
}

private struct MonitoringLogCurrentSnapshot: Codable {
    let exportedAt: Date
    let system: MonitoringSystemLogSnapshot?
    let fans: MonitoringFanLogSnapshot?
    let latestCoolModeDecision: MonitoringCoolModeDecision?
}

private struct MonitoringLogManifest: Codable {
    let schemaVersion: Int
    let applicationName: String
    let exportedAt: Date
    let recordingWasEnabled: Bool
    let samplingIntervalSeconds: Int
    let retentionIntervalSeconds: TimeInterval
    let maximumStorageBytes: Int64
    let historicalCoverageStart: Date?
    let historicalCoverageEnd: Date?
    let containsHistoricalRecords: Bool
    let includedFiles: [String]
}

private final class MonitoringLogJournal {
    enum Category: String, CaseIterable {
        case system = "system-snapshots"
        case fans = "fan-snapshots"
        case coolMode = "cool-mode-decisions"

        var fileName: String { "\(rawValue).jsonl" }
    }

    struct Coverage {
        let start: Date?
        let end: Date?
        let segmentCount: Int
        let includedFiles: [String]
    }

    private let fileManager = FileManager.default
    private let rootURL: URL
    private let writerQueue = DispatchQueue(label: "Mac-TaskManager.monitoring-log", qos: .utility)
    private let encoder: JSONEncoder
    private var isRecording = false
    private var activeSegmentURL: URL?
    private var activeSegmentStartedAt: Date?
    private var activeSegmentBytes: Int64 = 0
    private var handles: [Category: FileHandle] = [:]

    private let segmentInterval: TimeInterval = 10 * 60
    private let maximumSegmentBytes: Int64 = 32 * 1_024 * 1_024

    init(bundleIdentifier: String) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        rootURL = applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("MonitoringLogs", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    func startRecording() {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.isRecording = true
            self.prepareRootDirectory()
            self.rotateSegmentIfNeeded(force: self.activeSegmentURL == nil)
        }
    }

    func stopAndDelete() {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.closeHandles()
            self.activeSegmentURL = nil
            self.activeSegmentStartedAt = nil
            self.activeSegmentBytes = 0
            try? self.fileManager.removeItem(at: self.rootURL)
        }
    }

    func append<T: Encodable>(_ value: T, category: Category) {
        writerQueue.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.prepareRootDirectory()
            self.rotateSegmentIfNeeded(force: false)
            guard let line = self.encodedLine(value) else { return }
            self.append(line, category: category)
        }
    }

    func flush() {
        writerQueue.sync {
            synchronizeHandles()
        }
    }

    func copyRetainedSegments(to destinationRoot: URL) throws -> Coverage {
        try writerQueue.sync {
            synchronizeHandles()
            guard fileManager.fileExists(atPath: rootURL.path) else {
                return Coverage(start: nil, end: nil, segmentCount: 0, includedFiles: [])
            }
            cleanupExpiredSegments(now: Date())

            let logDestination = destinationRoot.appendingPathComponent("historical", isDirectory: true)
            try fileManager.createDirectory(
                at: logDestination,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let segments = sortedSegments()
            var includedFiles: [String] = []
            var coverageStart: Date?
            var coverageEnd: Date?

            for segment in segments {
                let destination = logDestination.appendingPathComponent(segment.url.lastPathComponent, isDirectory: true)
                try fileManager.copyItem(at: segment.url, to: destination)
                if coverageStart == nil { coverageStart = segment.date }
                coverageEnd = Date()

                for category in Category.allCases {
                    let candidate = destination.appendingPathComponent(category.fileName)
                    if fileManager.fileExists(atPath: candidate.path) {
                        includedFiles.append("historical/\(segment.url.lastPathComponent)/\(category.fileName)")
                    }
                }
            }

            return Coverage(
                start: coverageStart,
                end: coverageEnd,
                segmentCount: segments.count,
                includedFiles: includedFiles
            )
        }
    }

    private func prepareRootDirectory() {
        guard !fileManager.fileExists(atPath: rootURL.path) else { return }
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return
        }
    }

    private func rotateSegmentIfNeeded(force: Bool) {
        let now = Date()
        let shouldRotate =
            force
            || activeSegmentURL == nil
            || activeSegmentStartedAt.map { now.timeIntervalSince($0) >= segmentInterval } == true
            || activeSegmentBytes >= maximumSegmentBytes
        guard shouldRotate else { return }

        closeHandles()
        let segmentURL = rootURL.appendingPathComponent(segmentName(for: now), isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: segmentURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            activeSegmentURL = segmentURL
            activeSegmentStartedAt = now
            activeSegmentBytes = 0
            cleanupExpiredSegments(now: now)
        } catch {
            activeSegmentURL = nil
            activeSegmentStartedAt = nil
            activeSegmentBytes = 0
        }
    }

    private func append(_ data: Data, category: Category) {
        guard let activeSegmentURL else { return }
        let handle: FileHandle
        do {
            if let existing = handles[category] {
                handle = existing
            } else {
                let fileURL = activeSegmentURL.appendingPathComponent(category.fileName)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                let opened = try FileHandle(forWritingTo: fileURL)
                try opened.seekToEnd()
                handles[category] = opened
                handle = opened
            }
            try handle.write(contentsOf: data)
            activeSegmentBytes += Int64(data.count)
        } catch {
            return
        }
    }

    private func encodedLine<T: Encodable>(_ value: T) -> Data? {
        guard var data = try? encoder.encode(value) else { return nil }
        data.append(contentsOf: [0x0A])
        return data
    }

    private func closeHandles() {
        for handle in handles.values {
            try? handle.synchronize()
            try? handle.close()
        }
        handles.removeAll()
    }

    private func synchronizeHandles() {
        for handle in handles.values {
            try? handle.synchronize()
        }
    }

    private func cleanupExpiredSegments(now: Date) {
        var segments = sortedSegments()
        let cutoff = now.addingTimeInterval(-MonitoringLogPreferences.retentionInterval)
        for segment in segments where segment.date < cutoff {
            if segment.url == activeSegmentURL { continue }
            try? fileManager.removeItem(at: segment.url)
        }

        segments = sortedSegments()
        var totalBytes = segments.reduce(Int64(0)) { $0 + directorySize(at: $1.url) }
        for segment in segments where totalBytes > MonitoringLogPreferences.maximumStorageBytes {
            if segment.url == activeSegmentURL { continue }
            let bytes = directorySize(at: segment.url)
            try? fileManager.removeItem(at: segment.url)
            totalBytes -= bytes
        }
    }

    private func sortedSegments() -> [(url: URL, date: Date)] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return (url, date)
        }
        .sorted { $0.date < $1.date }
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var bytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return bytes
    }

    private func segmentName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

extension SystemMonitor {
    func monitoringLogSnapshot(at timestamp: Date = Date()) -> MonitoringSystemLogSnapshot {
        MonitoringSystemLogSnapshot(
            timestamp: timestamp,
            cpu: MonitoringCPULog(
                totalUsage: totalCPU,
                cores: cpuCores.map {
                    MonitoringCPUCoreLog(index: $0.id, usage: $0.usage)
                }
            ),
            gpuUsage: totalGPU,
            memory: MonitoringMemoryLog(
                usedBytes: usedMemory,
                totalBytes: totalMemory,
                usagePercent: totalMemory > 0 ? Double(usedMemory) / Double(totalMemory) * 100 : 0
            ),
            disk: MonitoringDiskLog(
                totalBytesPerSecond: totalDiskBytesPerSecond,
                readBytesPerSecond: diskReadBytesPerSecond,
                writeBytesPerSecond: diskWriteBytesPerSecond
            ),
            network: MonitoringNetworkLog(
                totalBytesPerSecond: totalNetworkBytesPerSecond,
                receiveBytesPerSecond: networkReceiveBytesPerSecond,
                sendBytesPerSecond: networkSendBytesPerSecond
            ),
            processes: processes.map { $0.monitoringLogRecord },
            ports: ports.map {
                MonitoringPortLog(
                    port: $0.port,
                    process: $0.process,
                    pid: $0.pid,
                    protocolName: $0.proto
                )
            },
            hardware: MonitoringHardwareLog(
                cpuName: hardwareInfo.cpuName,
                cpuDisplayName: hardwareInfo.cpuDisplayName,
                physicalCPUCount: hardwareInfo.physicalCPUCount,
                logicalCPUCount: hardwareInfo.logicalCPUCount,
                memoryCapacity: hardwareInfo.memoryCapacity,
                diskName: hardwareInfo.diskName,
                diskCapacity: hardwareInfo.diskCapacity,
                wifiInterface: hardwareInfo.wifiInterface,
                wifiSSID: hardwareInfo.wifiSSID,
                gpuName: hardwareInfo.gpuName,
                gpuDisplayName: hardwareInfo.gpuDisplayName
            )
        )
    }
}

extension AppProcess {
    var monitoringLogRecord: MonitoringProcessLog {
        MonitoringProcessLog(
            pid: pid,
            parentPID: parentPID,
            name: name,
            user: user,
            isApplication: isApp,
            status: monitoringLogStatus,
            runningSeconds: runningSeconds,
            cpuUsage: cpuUsage,
            gpuUsage: gpuUsage,
            memoryUsageBytes: memoryUsage,
            diskBytesPerSecond: diskBytesPerSecond,
            networkBytesPerSecond: networkBytesPerSecond
        )
    }

    private var monitoringLogStatus: String {
        switch status {
        case .none: return "normal"
        case .efficiency: return "efficiency"
        case .suspended: return "suspended"
        }
    }
}

extension FanReading {
    var monitoringLogRecord: MonitoringFanLog {
        MonitoringFanLog(
            index: index,
            actualRPM: actualRPM,
            targetRPM: targetRPM,
            minimumRPM: minimumRPM,
            maximumRPM: maximumRPM,
            isManual: isManual
        )
    }
}

extension TemperatureReading {
    var monitoringLogRecord: MonitoringTemperatureLog {
        MonitoringTemperatureLog(
            key: key,
            name: name,
            group: group.rawValue,
            celsius: celsius
        )
    }
}

extension CoolModeInput {
    var monitoringLogRecord: MonitoringCoolModeInputLog {
        MonitoringCoolModeInputLog(
            cpuUsage: cpuUsage,
            gpuUsage: gpuUsage,
            memoryUsage: memoryUsage,
            diskBytesPerSecond: diskBytesPerSecond,
            cpuTemperature: cpuTemperature,
            gpuTemperature: gpuTemperature,
            systemTemperature: systemTemperature
        )
    }
}

extension CoolModeAssessment {
    var monitoringLogRecord: MonitoringCoolModeAssessmentLog {
        MonitoringCoolModeAssessmentLog(
            heatLevel: heatLevel.rawValue,
            predictedHeatScore: predictedHeatScore,
            workloadScore: workloadScore,
            temperatureScore: temperatureScore,
            risingBonus: risingBonus,
            requestedCoolingDemand: requestedCoolingDemand,
            coolingDemand: coolingDemand,
            previousCoolingDemand: previousCoolingDemand,
            smoothingAction: smoothingAction.rawValue,
            dominantFactor: dominantFactor,
            highestTemperature: highestTemperature,
            temperatureRise: temperatureRise
        )
    }
}
