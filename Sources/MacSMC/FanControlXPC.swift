import Foundation

public enum FanControlXPC {
    public static let serviceName = "local.Mac-TaskManager.FanHelper"
    public static let mainApplicationIdentifier = "local.Mac-TaskManager"
    public static let launchDaemonPlistName = "\(serviceName).plist"
}

@objc public protocol FanControlXPCProtocol {
    func ping(withReply reply: @escaping (Bool, String?) -> Void)
    func setFanRPM(
        index: Int,
        rpm: Double,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    func setFanAutomatic(
        index: Int,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    func updateCoolModeTargets(
        indexes: [NSNumber],
        rpms: [NSNumber],
        withReply reply: @escaping (Bool, String?) -> Void
    )
    func stopCoolMode(withReply reply: @escaping (Bool, String?) -> Void)
}
