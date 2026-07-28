import Foundation
import IOKit

public enum SMCError: LocalizedError, Equatable {
    case connectionFailed(Int32)
    case invalidKey(String)
    case keyNotFound(String)
    case invalidFanIndex(Int)
    case invalidRPM(Int, minimum: Int, maximum: Int)
    case ioKit(Int32)
    case firmware(UInt8)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let code):
            return "无法连接 AppleSMC（0x\(String(UInt32(bitPattern: code), radix: 16))）"
        case .invalidKey(let key):
            return "SMC 键格式无效：\(key)"
        case .keyNotFound(let key):
            return "此 Mac 不提供 SMC 键 \(key)"
        case .invalidFanIndex(let index):
            return "风扇编号无效：\(index)"
        case .invalidRPM(let rpm, let minimum, let maximum):
            return "转速 \(rpm) RPM 超出安全范围 \(minimum)–\(maximum) RPM"
        case .ioKit(let code):
            return "IOKit 操作失败（0x\(String(UInt32(bitPattern: code), radix: 16))）"
        case .firmware(let code):
            return "SMC 固件拒绝了操作（0x\(String(code, radix: 16))）"
        case .timeout:
            return "等待系统释放风扇控制权超时"
        }
    }
}

public struct FanReading: Identifiable, Equatable, Sendable {
    public let index: Int
    public let actualRPM: Double
    public let targetRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let isManual: Bool

    public var id: Int { index }

    public init(
        index: Int,
        actualRPM: Double,
        targetRPM: Double,
        minimumRPM: Double,
        maximumRPM: Double,
        isManual: Bool
    ) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.isManual = isManual
    }
}

public struct FanSnapshot: Equatable, Sendable {
    public let fans: [FanReading]
    public let temperatures: [TemperatureReading]
    public let hardwareModel: String

    public init(
        fans: [FanReading],
        temperatures: [TemperatureReading],
        hardwareModel: String
    ) {
        self.fans = fans
        self.temperatures = temperatures
        self.hardwareModel = hardwareModel
    }
}

public enum SMCValueCodec {
    public static func fanRPM(from bytes: [UInt8], size: UInt32) -> Double {
        if size == 4, bytes.count >= 4 {
            let value = bytes.withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(as: Float.self)
            }
            return Double(value)
        }

        guard bytes.count >= 2 else { return 0 }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(raw) / 4.0
    }

    public static func fanRPMBytes(_ rpm: Double, size: UInt32) -> [UInt8] {
        if size == 4 {
            var value = Float(rpm)
            return withUnsafeBytes(of: &value) { Array($0) }
        }

        let scaled = UInt16(max(0, min(Double(UInt16.max), rpm * 4.0)))
        return [UInt8(scaled >> 8), UInt8(scaled & 0xff)]
    }

    public static func temperature(
        from bytes: [UInt8],
        size: UInt32,
        dataType: String
    ) -> Double? {
        if dataType == "flt ", size == 4, bytes.count >= 4 {
            let value = bytes.withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(as: Float.self)
            }
            return Double(value)
        }

        if dataType == "sp78", bytes.count >= 2 {
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        }

        if size == 4, bytes.count >= 4 {
            let value = bytes.withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(as: Float.self)
            }
            return Double(value)
        }

        if bytes.count >= 2 {
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        }

        return nil
    }
}

public final class SMCController {
    private let connection: io_connect_t

    public init() throws {
        guard let matching = IOServiceMatching("AppleSMC") else {
            throw SMCError.connectionFailed(kIOReturnNotFound)
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            throw SMCError.connectionFailed(kIOReturnNotFound)
        }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
        guard result == kIOReturnSuccess else {
            throw SMCError.connectionFailed(result)
        }
        connection = openedConnection
    }

    deinit {
        IOServiceClose(connection)
    }

    public func snapshot() throws -> FanSnapshot {
        let hardwareModel = Self.hardwareModel()
        let count = (try? fanCount()) ?? 0
        let modeFormat = detectedModeKeyFormat()
        var fans: [FanReading] = []
        for index in 0..<count {
            let actual = try readFanValue(key: fanKey("F%dAc", index: index))
            let target = try readFanValue(key: fanKey("F%dTg", index: index))
            let minimum = try readFanValue(key: fanKey("F%dMn", index: index))
            let maximum = try readFanValue(key: fanKey("F%dMx", index: index))
            let mode = try? readKey(fanKey(modeFormat, index: index)).bytes.first
            fans.append(FanReading(
                index: index,
                actualRPM: actual,
                targetRPM: target,
                minimumRPM: minimum,
                maximumRPM: maximum,
                isManual: mode == 1
            ))
        }

        return FanSnapshot(
            fans: fans,
            temperatures: temperatureSensors(hardwareModel: hardwareModel),
            hardwareModel: hardwareModel
        )
    }

    public func setFanRPM(index: Int, rpm: Double) throws {
        let count = try fanCount()
        guard (0..<count).contains(index) else {
            throw SMCError.invalidFanIndex(index)
        }

        let minimum = try readFanValue(key: fanKey("F%dMn", index: index))
        let maximum = try readFanValue(key: fanKey("F%dMx", index: index))
        let roundedRPM = Int(rpm.rounded())
        guard rpm >= minimum, rpm <= maximum, minimum > 0, maximum >= minimum else {
            throw SMCError.invalidRPM(
                roundedRPM,
                minimum: Int(minimum.rounded()),
                maximum: Int(maximum.rounded())
            )
        }

        let modeKey = fanKey(detectedModeKeyFormat(), index: index)
        do {
            try writeKey(modeKey, bytes: [1])
        } catch {
            guard keyExists("Ftst") else { throw error }
            try writeKey("Ftst", bytes: [1])
            Thread.sleep(forTimeInterval: 0.5)

            let deadline = Date().addingTimeInterval(10)
            var manualModeEnabled = false
            while Date() < deadline {
                do {
                    try writeKey(modeKey, bytes: [1])
                    if (try? readKey(modeKey).bytes.first) == 1 {
                        manualModeEnabled = true
                        break
                    }
                } catch {
                    // AppleSMC can reject writes briefly while macOS releases
                    // automatic fan control. Retry until the deadline below.
                }
                Thread.sleep(forTimeInterval: 0.1)
            }

            guard manualModeEnabled else {
                throw SMCError.timeout
            }
        }

        let targetKey = fanKey("F%dTg", index: index)
        let info = try keyInfo(targetKey)
        try writeKey(targetKey, bytes: SMCValueCodec.fanRPMBytes(rpm, size: info.dataSize))
    }

    public func setFanAutomatic(index: Int) throws {
        let count = try fanCount()
        guard (0..<count).contains(index) else {
            throw SMCError.invalidFanIndex(index)
        }

        let modeFormat = detectedModeKeyFormat()
        let modeKey = fanKey(modeFormat, index: index)
        try writeKey(modeKey, bytes: [0])

        let targetKey = fanKey("F%dTg", index: index)
        if let info = try? keyInfo(targetKey) {
            try? writeKey(targetKey, bytes: SMCValueCodec.fanRPMBytes(0, size: info.dataSize))
        }

        let otherFanIsManual = (0..<count)
            .filter { $0 != index }
            .contains { otherIndex in
                (try? readKey(fanKey(modeFormat, index: otherIndex)).bytes.first) == 1
            }

        if !otherFanIsManual, keyExists("Ftst") {
            try? writeKey("Ftst", bytes: [0])
        }
    }

    public func fanCount() throws -> Int {
        let (bytes, _) = try readKey("FNum")
        guard let count = bytes.first else {
            throw SMCError.keyNotFound("FNum")
        }
        return Int(count)
    }

    public func temperatureSensors() -> [TemperatureReading] {
        temperatureSensors(hardwareModel: Self.hardwareModel())
    }

    public func availableTemperatureKeys() -> [(key: String, celsius: Double)] {
        enumerateKeys()
            .filter { $0.hasPrefix("T") }
            .compactMap { key in
                guard let info = try? keyInfo(key),
                      let value = try? readKey(key),
                      let celsius = SMCValueCodec.temperature(
                          from: value.bytes,
                          size: value.size,
                          dataType: dataTypeString(info.dataType)
                      ),
                      celsius > 0,
                      celsius < 130 else {
                    return nil
                }
                return (key, celsius)
            }
    }

    public static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return "Mac"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            return "Mac"
        }
        return String(bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? "Mac"
    }

    private func readFanValue(key: String) throws -> Double {
        let (bytes, size) = try readKey(key)
        return SMCValueCodec.fanRPM(from: bytes, size: size)
    }

    private func temperatureSensors(hardwareModel: String) -> [TemperatureReading] {
        TemperatureSensorCatalog.definitions(for: hardwareModel)
            .compactMap { definition in
                guard let info = try? keyInfo(definition.key),
                      let value = try? readKey(definition.key),
                      let celsius = SMCValueCodec.temperature(
                          from: value.bytes,
                          size: value.size,
                          dataType: dataTypeString(info.dataType)
                      ),
                      celsius > 0,
                      celsius < 130 else {
                    return nil
                }

                return TemperatureReading(
                    key: definition.key,
                    name: definition.name,
                    group: definition.group,
                    celsius: celsius
                )
            }
            .sorted {
                if $0.group.sortOrder != $1.group.sortOrder {
                    return $0.group.sortOrder < $1.group.sortOrder
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private func dataTypeString(_ dataType: UInt32) -> String {
        withUnsafeBytes(of: dataType.bigEndian) { rawBuffer in
            String(bytes: rawBuffer, encoding: .ascii) ?? ""
        }
    }

    private func enumerateKeys() -> [String] {
        guard let (countBytes, countSize) = try? readKey("#KEY"),
              countSize >= 4 else {
            return []
        }

        let count = countBytes.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))

        for index in 0..<count {
            var input = SMCParamStruct()
            input.data8 = SMCCommand.readIndex.rawValue
            input.data32 = index
            guard let output = try? call(input) else { continue }
            let key = [
                UInt8((output.key >> 24) & 0xff),
                UInt8((output.key >> 16) & 0xff),
                UInt8((output.key >> 8) & 0xff),
                UInt8(output.key & 0xff)
            ]
            if let value = String(bytes: key, encoding: .ascii) {
                keys.append(value)
            }
        }
        return keys
    }

    private func detectedModeKeyFormat() -> String {
        for format in ["F%dmd", "F%dMd"] where keyExists(fanKey(format, index: 0)) {
            return format
        }
        return "F%dMd"
    }

    private func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    private func fanKey(_ format: String, index: Int) -> String {
        String(format: format, index)
    }

    private func readKey(_ key: String) throws -> (bytes: [UInt8], size: UInt32) {
        let keyInformation = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = try fourCharacterCode(key)
        input.keyInfo.dataSize = keyInformation.dataSize
        input.data8 = SMCCommand.readBytes.rawValue
        let output = try call(input)
        try validateFirmwareResult(output.result, key: key)

        let bytes = withUnsafeBytes(of: output.bytes) { rawBuffer in
            Array(rawBuffer.prefix(Int(keyInformation.dataSize)))
        }
        return (bytes, keyInformation.dataSize)
    }

    private func writeKey(_ key: String, bytes: [UInt8]) throws {
        let keyInformation = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = try fourCharacterCode(key)
        input.keyInfo.dataSize = keyInformation.dataSize
        input.data8 = SMCCommand.writeBytes.rawValue
        input.bytes = makeByteTuple(bytes)
        let output = try call(input)
        try validateFirmwareResult(output.result, key: key)
    }

    private func keyInfo(_ key: String) throws -> SMCParamStruct.KeyInfo {
        var input = SMCParamStruct()
        input.key = try fourCharacterCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        let output = try call(input)
        try validateFirmwareResult(output.result, key: key)
        return output.keyInfo
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var request = input
        var response = SMCParamStruct()
        var responseSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCCommand.kernelIndex.rawValue),
            &request,
            MemoryLayout<SMCParamStruct>.stride,
            &response,
            &responseSize
        )
        guard result == kIOReturnSuccess else {
            throw SMCError.ioKit(result)
        }
        return response
    }

    private func validateFirmwareResult(_ result: UInt8, key: String) throws {
        guard result == 0 else {
            if result == 0x84 {
                throw SMCError.keyNotFound(key)
            }
            throw SMCError.firmware(result)
        }
    }

    private func fourCharacterCode(_ key: String) throws -> UInt32 {
        guard key.utf8.count == 4 else {
            throw SMCError.invalidKey(key)
        }
        return key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func makeByteTuple(_ bytes: [UInt8]) -> SMCParamStruct.Bytes32 {
        let values = Array((bytes + Array(repeating: 0, count: 32)).prefix(32))
        return (
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11],
            values[12], values[13], values[14], values[15],
            values[16], values[17], values[18], values[19],
            values[20], values[21], values[22], values[23],
            values[24], values[25], values[26], values[27],
            values[28], values[29], values[30], values[31]
        )
    }
}

private enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

private struct SMCParamStruct {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PowerLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var memory: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var powerLimit = PowerLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
