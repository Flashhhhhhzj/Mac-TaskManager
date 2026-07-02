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
    let name: String
    let cpuUsage: Double
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

// MARK: - System Monitor
class SystemMonitor: ObservableObject {
    @Published var processes: [AppProcess] = []
    @Published var cpuCores: [CPUCore] = []
    @Published var totalCPU: Double = 0.0
    @Published var totalMemory: UInt64 = 0
    @Published var usedMemory: UInt64 = 0
    @Published var ports: [PortEntry] = []

    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "MacSystemMonitor.refresh", qos: .background)
    private let networkQueue = DispatchQueue(label: "MacSystemMonitor.network", qos: .utility)
    private let networkLock = NSLock()
    private var previousCoreInfo: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var previousDiskTotals: [Int32: UInt64] = [:]
    private var previousNetworkTotals: [Int32: UInt64] = [:]
    private var networkRates: [Int32: Double] = [:]
    private var isNetworkSampling = false
    private var previousProcessSampleTime: Date?
    private var previousNetworkSampleTime: Date?

    init() {
        startMonitoring()
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

    func updateProcesses() {
        var processes: [AppProcess] = []
        var currentDiskTotals: [Int32: UInt64] = [:]
        let sampleTime = Date()
        let elapsed = previousProcessSampleTime.map { max(sampleTime.timeIntervalSince($0), 0.1) }
        let processorCount = max(Foundation.ProcessInfo.processInfo.activeProcessorCount, 1)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,pcpu=,rss=,user=,command="]

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

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let components = trimmed.split(
                separator: " ",
                maxSplits: 4,
                omittingEmptySubsequences: true
            )
            guard components.count >= 5 else { continue }

            guard let pid = Int32(components[0]),
                  let cpu = Double(components[1]),
                  let rss = UInt64(components[2]) else { continue }

            let user = String(components[3])
            let normalizedCPU = min(cpu / Double(processorCount), 100)
            let command = String(components[4])
            let matchedApp = appMap[pid]
            let isApp = matchedApp?.activationPolicy == .regular
            let name = displayName(pid: pid, command: command, app: matchedApp, isApp: isApp)
            let icon: NSImage? = matchedApp?.icon ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            let diskTotal = diskBytes(for: pid)
            let diskBytesPerSecond: Double
            if let elapsed, let previousTotal = previousDiskTotals[pid], diskTotal >= previousTotal {
                diskBytesPerSecond = Double(diskTotal - previousTotal) / elapsed
            } else {
                diskBytesPerSecond = 0
            }
            currentDiskTotals[pid] = diskTotal
            let networkBytesPerSecond = networkRate(for: pid)

            guard !name.isEmpty else { continue }

            processes.append(AppProcess(
                pid: pid,
                name: name,
                cpuUsage: normalizedCPU,
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

        DispatchQueue.main.async {
            self.processes = self.sortProcessesByMemory(processes)
        }
    }

    private func sortProcessesByMemory(_ processes: [AppProcess]) -> [AppProcess] {
        processes.sorted {
            if $0.memoryUsage != $1.memoryUsage { return $0.memoryUsage > $1.memoryUsage }
            if $0.cpuUsage != $1.cpuUsage { return $0.cpuUsage > $1.cpuUsage }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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

    private func diskBytes(for pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return 0 }
        return info.ri_diskio_bytesread + info.ri_diskio_byteswritten
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
        for (pid, total) in totals {
            guard let previousTotal = previousNetworkTotals[pid], total >= previousTotal else { continue }
            rates[pid] = Double(total - previousTotal) / elapsed
        }

        previousNetworkTotals = totals
        previousNetworkSampleTime = sampleTime
        networkLock.lock()
        networkRates = rates
        networkLock.unlock()
    }

    private func networkBytesByPID() -> [Int32: UInt64] {
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
        var totals: [Int32: UInt64] = [:]

        for line in output.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let processIDPart = String(parts[0])
            guard let dotIndex = processIDPart.lastIndex(of: "."),
                  let pid = Int32(processIDPart[processIDPart.index(after: dotIndex)...]),
                  let bytesIn = UInt64(parts[1]),
                  let bytesOut = UInt64(parts[2]) else { continue }
            totals[pid] = bytesIn + bytesOut
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
            }
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

    func killProcess(pid: Int32) {
        kill(pid, SIGTERM)
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
    @Published var searchText = ""
    @Published var selectedPID: Int32?
    @Published var showRunTaskDialog = false
    @Published var runTaskCommand = ""
    @Published var runTaskError = ""
    @Published var efficiencyPIDs: Set<Int32> = []
    @Published var frozenProcessOrder: [Int32]?
}

enum TaskManagerStyle {
    static let contentWidth: CGFloat = 1023
    static let contentHeight: CGFloat = 726
    static let shadowMargin: CGFloat = 16
    static let cornerRadius: CGFloat = 8
    static let chrome = Color(red: 0.937, green: 0.949, blue: 0.973)
    static let sidebar = Color(red: 0.929, green: 0.949, blue: 0.976)
    static let selectedSidebar = Color(red: 0.910, green: 0.918, blue: 0.941)
    static let grid = Color(red: 0.914, green: 0.914, blue: 0.914)
    static let chromeRule = Color(red: 0.886, green: 0.898, blue: 0.918)
    static let headerCell = Color(red: 0.965, green: 0.965, blue: 0.965)
    static let resource = Color(red: 0.839, green: 0.945, blue: 1.000)
    static let resourceHot = Color(red: 0.612, green: 0.867, blue: 1.000)
    static let selectedRow = Color(red: 0.910, green: 0.941, blue: 0.984)
    static let text = Color(red: 0.055, green: 0.067, blue: 0.082)
    static let muted = Color(red: 0.365, green: 0.392, blue: 0.431)
}

struct ResourceSample {
    let diskBytesPerSecond: Double
    let networkBytesPerSecond: Double
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
                            TaskManagerSecondaryPage(index: state.selectedNav, monitor: monitor)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: TaskManagerStyle.contentWidth, height: TaskManagerStyle.contentHeight)
            .background {
                RoundedRectangle(cornerRadius: TaskManagerStyle.cornerRadius, style: .continuous)
                    .fill(Color.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: TaskManagerStyle.cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.26), radius: 14, x: 0, y: 8)
            .overlay {
                RoundedRectangle(cornerRadius: TaskManagerStyle.cornerRadius, style: .continuous)
                    .stroke(Color(red: 0.333, green: 0.408, blue: 0.545), lineWidth: 1)
            }
        }
        .frame(
            width: TaskManagerStyle.contentWidth + TaskManagerStyle.shadowMargin * 2,
            height: TaskManagerStyle.contentHeight + TaskManagerStyle.shadowMargin * 2
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

struct TaskManagerTitleBar: View {
    @ObservedObject var state: ContentViewState

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
                        .font(.system(size: 14))
                        .foregroundColor(TaskManagerStyle.text)
                }
                .frame(width: 272, alignment: .leading)
                .padding(.leading, 22)

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundColor(TaskManagerStyle.muted)
                    ZStack(alignment: .leading) {
                        if state.searchText.isEmpty {
                            Text("键入要搜索的名称、发布者或 PID")
                                .font(.system(size: 16))
                                .foregroundColor(Color(red: 0.620, green: 0.640, blue: 0.670))
                        }
                        TextField("", text: $state.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
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

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 19))
                .frame(width: 48, height: 42)
                .padding(.top, 7)

            ForEach(Array(icons.enumerated()), id: \.offset) { item in
                SidebarButton(icon: item.element, selected: state.selectedNav == item.offset) {
                    state.selectedNav = item.offset
                }
            }

            Spacer()

            SidebarButton(icon: "gearshape", selected: false) {}
                .padding(.bottom, 14)
        }
        .frame(width: 62)
        .background(TaskManagerStyle.sidebar)
    }
}

struct SidebarButton: View {
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? TaskManagerStyle.selectedSidebar : Color.clear)
                    .frame(width: selected ? 50 : 50, height: selected ? 44 : 42)
                    .offset(x: selected ? -1 : 0, y: selected ? 2 : 0)
                if selected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(red: 0.000, green: 0.404, blue: 0.753))
                        .frame(width: 5, height: 20)
                        .offset(x: -2, y: 1)
                }
                SidebarFluentIcon(icon: icon)
                    .frame(width: 50, height: 42)
            }
            .frame(width: 50, height: 42)
        }
        .buttonStyle(.plain)
        .frame(width: 50, height: 42)
    }
}

struct SidebarFluentIcon: View {
    let icon: String

    var body: some View {
        Group {
            if icon == "square.grid.2x2" {
                ProcessGlyph()
                    .stroke(TaskManagerStyle.text, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 18)
            } else if icon == "waveform.path.ecg" {
                PerformanceGlyph()
                    .stroke(TaskManagerStyle.text, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 19, height: 19)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(TaskManagerStyle.text)
            }
        }
    }
}

struct ProcessGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let gap = rect.width * 0.07
        let cell = (rect.width - gap) / 2
        let radius = rect.width * 0.12
        let topLeft = CGRect(x: rect.minX, y: rect.minY, width: cell, height: cell)
        let topRight = CGRect(x: rect.minX + cell + gap, y: rect.minY, width: cell, height: cell)
        let bottomLeft = CGRect(x: rect.minX, y: rect.minY + cell + gap, width: cell, height: cell)
        path.addRoundedRect(in: topLeft, cornerSize: CGSize(width: radius, height: radius))
        path.addRoundedRect(in: topRight, cornerSize: CGSize(width: radius, height: radius))
        path.addRoundedRect(in: bottomLeft, cornerSize: CGSize(width: radius, height: radius))
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
            monitor.killProcess(pid: process.pid)
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
            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(TaskManagerStyle.text)
                    .padding(.leading, 20)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(Color.white)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TaskManagerStyle.grid)
                    .frame(height: 1)
            }

            if index == 1 {
                VStack(alignment: .leading, spacing: 16) {
                    MetricSummaryRow(title: "CPU", value: String(format: "%.0f%%", monitor.totalCPU))
                    MetricSummaryRow(title: "内存", value: String(format: "%.0f%%", memoryPercent))
                    MetricSummaryRow(title: "逻辑处理器", value: "\(monitor.cpuCores.count)")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
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
    let statusWidth: CGFloat = 150
    let metricWidth: CGFloat = 91

    var matchingProcesses: [AppProcess] {
        let search = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return monitor.processes.filter { process in
            search.isEmpty ||
                process.name.localizedCaseInsensitiveContains(search) ||
                process.user.localizedCaseInsensitiveContains(search) ||
                String(process.pid).contains(search)
        }
    }

    var filteredProcesses: [AppProcess] {
        let normallySorted = normallySortedProcesses(matchingProcesses)
        guard let frozenProcessOrder = state.frozenProcessOrder else { return normallySorted }

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

    func normallySortedProcesses(_ processes: [AppProcess]) -> [AppProcess] {
        processes.sorted {
            if $0.isApp != $1.isApp { return $0.isApp && !$1.isApp }
            if $0.memoryUsage != $1.memoryUsage { return $0.memoryUsage > $1.memoryUsage }
            if $0.cpuUsage != $1.cpuUsage { return $0.cpuUsage > $1.cpuUsage }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var appProcesses: [AppProcess] {
        filteredProcesses.filter { $0.isApp }
    }

    var backgroundProcesses: [AppProcess] {
        filteredProcesses.filter { !$0.isApp }
    }

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
        VStack(alignment: .leading, spacing: 0) {
            TableHeader(
                nameWidth: nameWidth,
                statusWidth: statusWidth,
                metricWidth: metricWidth,
                cpu: monitor.totalCPU,
                memory: memoryPercent,
                disk: diskPercent,
                network: networkPercent
            )

            ScrollView {
                LazyVStack(spacing: 0) {
                    ProcessGroupHeader(title: "应用", count: appProcesses.count, nameWidth: nameWidth, statusWidth: statusWidth, metricWidth: metricWidth)

                    ForEach(appProcesses) { process in
                        ProcessTableRow(
                            process: process,
                            selected: state.selectedPID == process.pid,
                            nameWidth: nameWidth,
                            statusWidth: statusWidth,
                            metricWidth: metricWidth,
                            sample: resourceSample(for: process),
                            efficiencyEnabled: state.efficiencyPIDs.contains(process.pid)
                        )
                        .onTapGesture {
                            state.selectedPID = process.pid
                        }
                        .onHover { hovering in
                            if hovering {
                                state.selectedPID = process.pid
                            }
                        }
                    }

                    ProcessGroupHeader(title: "后台进程", count: backgroundProcesses.count, nameWidth: nameWidth, statusWidth: statusWidth, metricWidth: metricWidth)

                    ForEach(backgroundProcesses) { process in
                        ProcessTableRow(
                            process: process,
                            selected: state.selectedPID == process.pid,
                            nameWidth: nameWidth,
                            statusWidth: statusWidth,
                            metricWidth: metricWidth,
                            sample: resourceSample(for: process),
                            efficiencyEnabled: state.efficiencyPIDs.contains(process.pid)
                        )
                        .onTapGesture {
                            state.selectedPID = process.pid
                        }
                        .onHover { hovering in
                            if hovering {
                                state.selectedPID = process.pid
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
                .frame(width: nameWidth + statusWidth + metricWidth * 4, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering in
                if hovering {
                    if state.frozenProcessOrder == nil {
                        state.frozenProcessOrder = filteredProcesses.map(\.pid)
                    }
                } else {
                    state.frozenProcessOrder = nil
                }
            }
        }
        .background(Color.white)
        .overlay(alignment: .trailing) {
            TaskManagerScrollBar()
                .padding(.top, 85)
                .padding(.trailing, 9)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TaskManagerStyle.grid)
                .frame(height: 1)
                .offset(y: 63)
        }
    }

    func resourceSample(for process: AppProcess) -> ResourceSample {
        ResourceSample(
            diskBytesPerSecond: process.diskBytesPerSecond,
            networkBytesPerSecond: process.networkBytesPerSecond
        )
    }
}

struct TableHeader: View {
    let nameWidth: CGFloat
    let statusWidth: CGFloat
    let metricWidth: CGFloat
    let cpu: Double
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

            Text("状态")
                .font(.system(size: 14))
                .foregroundColor(TaskManagerStyle.muted)
                .offset(y: -7)
                .padding(.leading, 8)
                .frame(width: statusWidth, height: 64, alignment: .bottomLeading)
                .background(TaskManagerStyle.headerCell)
                .overlay(alignment: .trailing) {
                    VerticalRule()
                }

            MetricHeader(value: String(format: "%.0f%%", cpu), title: "CPU", width: metricWidth)
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
    let statusWidth: CGFloat
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
                .frame(width: statusWidth, height: 48)
                .overlay(alignment: .trailing) {
                    VerticalRule()
                }

            ForEach(0..<4, id: \.self) { _ in
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
    let selected: Bool
    let nameWidth: CGFloat
    let statusWidth: CGFloat
    let metricWidth: CGFloat
    let sample: ResourceSample
    let efficiencyEnabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)
                    .frame(width: 16)

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

                Text(displayName(for: process))
                    .font(.system(size: 15))
                    .foregroundColor(.black)
                    .lineLimit(1)
            }
            .offset(y: 2)
            .padding(.leading, 22)
            .frame(width: nameWidth, height: 34, alignment: .leading)
            .background(selected ? TaskManagerStyle.selectedRow : Color.white)
            .overlay(alignment: .trailing) {
                VerticalRule()
            }

            HStack {
                Spacer()
                let effectiveStatus: ProcessStatus = efficiencyEnabled ? .efficiency : process.status
                if effectiveStatus == .efficiency {
                    Image(systemName: "leaf")
                        .font(.system(size: 17))
                        .foregroundColor(Color(red: 0.050, green: 0.620, blue: 0.200))
                } else if effectiveStatus == .suspended {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 17))
                        .foregroundColor(.orange)
                }
                Spacer()
            }
            .frame(width: statusWidth, height: 34)
            .background(selected ? TaskManagerStyle.selectedRow : Color.white)
            .overlay(alignment: .trailing) {
                VerticalRule()
            }

            ResourceCell(text: formatCPU(process.cpuUsage), width: metricWidth, intensity: min(process.cpuUsage / 12, 1))
            ResourceCell(text: formatMemory(process.memoryUsage), width: metricWidth, intensity: memoryIntensity(process.memoryUsage))
            ResourceCell(text: formatDisk(sample.diskBytesPerSecond), width: metricWidth, intensity: diskIntensity(sample.diskBytesPerSecond))
            ResourceCell(text: formatNetwork(sample.networkBytesPerSecond), width: metricWidth, intensity: networkIntensity(sample.networkBytesPerSecond))
        }
        .contentShape(Rectangle())
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

struct TaskManagerScrollBar: View {
    var body: some View {
        VStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(red: 0.522, green: 0.522, blue: 0.522))
                .frame(width: 3, height: 30)
            Spacer()
        }
        .frame(width: 5)
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
            window.hasShadow = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
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
