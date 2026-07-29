import AppKit
import Foundation
import MacSMC
import ServiceManagement
import SwiftUI

enum FanHelperRegistration {
    private static let registeredBuildKey = "FanHelperRegisteredBuild"
    private static let onboardingDismissedBuildKey = "FanHelperOnboardingDismissedBuild"

    enum RegistrationError: LocalizedError {
        case unregisterTimedOut

        var errorDescription: String? {
            switch self {
            case .unregisterTimedOut:
                return "等待旧版风扇控制服务退出超时，请重新启动 Mac-TaskManager 后再试。"
            }
        }
    }

    static var service: SMAppService {
        SMAppService.daemon(plistName: FanControlXPC.launchDaemonPlistName)
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var isCurrentBuildRegistered: Bool {
        UserDefaults.standard.string(forKey: registeredBuildKey) == currentBuild
    }

    static var wasOnboardingDismissedForCurrentBuild: Bool {
        UserDefaults.standard.string(forKey: onboardingDismissedBuildKey) == currentBuild
    }

    static func dismissOnboardingForCurrentBuild() {
        UserDefaults.standard.set(currentBuild, forKey: onboardingDismissedBuildKey)
    }

    static func registerOrRefresh() throws {
        let currentStatus = service.status
        let needsRefresh =
            !isCurrentBuildRegistered
            && currentStatus != .notRegistered
            && currentStatus != .notFound

        if needsRefresh {
            try unregisterAndWait()
        } else if currentStatus == .enabled || currentStatus == .requiresApproval {
            return
        }

        try service.register()
        UserDefaults.standard.set(currentBuild, forKey: registeredBuildKey)
        UserDefaults.standard.removeObject(forKey: onboardingDismissedBuildKey)
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func unregisterAndWait() throws {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var unregisterError: Error?

        service.unregister { error in
            lock.lock()
            unregisterError = error
            lock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 15) == .success else {
            throw RegistrationError.unregisterTimedOut
        }

        lock.lock()
        let error = unregisterError
        lock.unlock()
        if let error {
            throw error
        }
    }
}

@MainActor
final class FirstLaunchAuthorizationModel: ObservableObject {
    enum Phase: Equatable {
        case checking
        case notRegistered
        case needsUpdate
        case requiresApproval
        case enabled
        case failed(String)
    }

    @Published var isPresented = false
    @Published private(set) var phase: Phase = .checking
    @Published private(set) var isWorking = false

    func start() {
        refresh(presentWhenNeeded: true)
    }

    func refresh(presentWhenNeeded: Bool = false) {
        guard !isWorking else { return }

        switch FanHelperRegistration.service.status {
        case .enabled:
            if FanHelperRegistration.isCurrentBuildRegistered {
                phase = .enabled
                isPresented = false
            } else {
                phase = .needsUpdate
                if presentWhenNeeded
                    && !FanHelperRegistration.wasOnboardingDismissedForCurrentBuild {
                    isPresented = true
                }
            }
        case .requiresApproval:
            phase = FanHelperRegistration.isCurrentBuildRegistered
                ? .requiresApproval
                : .needsUpdate
            if presentWhenNeeded
                && !FanHelperRegistration.wasOnboardingDismissedForCurrentBuild {
                isPresented = true
            }
        case .notRegistered, .notFound:
            phase = .notRegistered
            if presentWhenNeeded
                && !FanHelperRegistration.wasOnboardingDismissedForCurrentBuild {
                isPresented = true
            }
        @unknown default:
            phase = .failed("无法识别当前 macOS 的后台服务授权状态。")
            if presentWhenNeeded {
                isPresented = true
            }
        }
    }

    func enableFullFunctionality() {
        if phase == .requiresApproval {
            FanHelperRegistration.openSystemSettings()
            return
        }

        guard !isWorking else { return }
        isWorking = true
        phase = .checking

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            do {
                try FanHelperRegistration.registerOrRefresh()
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.isWorking = false
                switch result {
                case .success:
                    self.refresh()
                    if self.phase == .requiresApproval {
                        FanHelperRegistration.openSystemSettings()
                    }
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                    self.isPresented = true
                }
            }
        }
    }

    func openSystemSettings() {
        FanHelperRegistration.openSystemSettings()
    }

    func dismissForNow() {
        FanHelperRegistration.dismissOnboardingForCurrentBuild()
        isPresented = false
    }
}

struct FirstLaunchAuthorizationView: View {
    @ObservedObject var model: FirstLaunchAuthorizationModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(TaskManagerStyle.onboardingAccentSurface)
                    .frame(width: 62, height: 62)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(red: 0.0, green: 0.40, blue: 0.75))
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(TaskManagerStyle.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    icon: "checkmark.circle.fill",
                    text: "进程、性能和温度读取无需额外授权"
                )
                permissionRow(
                    icon: "fanblades",
                    text: "风扇写入由签名验证的系统服务完成，并限制在硬件安全范围内"
                )
                permissionRow(
                    icon: "key.fill",
                    text: "首次批准后，日常调整不再重复输入管理员密码"
                )
            }
            .padding(14)
            .background(TaskManagerStyle.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 12) {
                Button("暂时跳过") {
                    model.dismissForNow()
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)

                Button(primaryButtonTitle) {
                    model.enableFullFunctionality()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }

            if model.isWorking {
                ProgressView("正在配置风扇控制服务…")
                    .controlSize(.small)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(TaskManagerStyle.surface)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.refresh()
        }
    }

    private var title: String {
        switch model.phase {
        case .checking:
            return "正在检查完整功能"
        case .notRegistered:
            return "启用完整的风扇控制"
        case .needsUpdate:
            return "更新风扇控制服务"
        case .requiresApproval:
            return "还需要一次系统批准"
        case .enabled:
            return "完整功能已启用"
        case .failed:
            return "风扇控制服务配置失败"
        }
    }

    private var detail: String {
        switch model.phase {
        case .checking:
            return "正在读取 macOS 后台服务状态。"
        case .notRegistered:
            return "macOS 要求用户亲自批准 root 后台服务；应用不能静默代替你授权。"
        case .needsUpdate:
            return "应用版本已更新。按 Apple 要求刷新 helper 注册，确保新签名和新路径生效。"
        case .requiresApproval:
            return "请在“系统设置 → 通用 → 登录项与扩展”中允许 Mac-TaskManager。"
        case .enabled:
            return "授权已经完成，可以直接使用全部功能。"
        case .failed(let message):
            return message
        }
    }

    private var primaryButtonTitle: String {
        switch model.phase {
        case .requiresApproval:
            return "打开系统设置"
        case .needsUpdate:
            return "更新并启用"
        case .failed:
            return "重新尝试"
        default:
            return "授权并启用"
        }
    }

    private func permissionRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(Color(red: 0.0, green: 0.40, blue: 0.75))
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(TaskManagerStyle.text)
        }
    }
}
