import CoreAudio
import Foundation

struct Configuration: Codable {
    var preferredDeviceName: String = "LS24A600U"
    var healthCheckIntervalSeconds: TimeInterval = 30
    var postWakeDelaySeconds: TimeInterval = 8
    var healthCheckTimeoutSeconds: TimeInterval = 3
    var minimumRecoveryCooldownSeconds: TimeInterval = 30
    var continuousRecovery: Bool = true
    var recoveryWindowSeconds: TimeInterval = 300

    private enum CodingKeys: String, CodingKey {
        case preferredDeviceName, healthCheckIntervalSeconds, postWakeDelaySeconds
        case healthCheckTimeoutSeconds, minimumRecoveryCooldownSeconds
        case continuousRecovery, recoveryWindowSeconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredDeviceName = try container.decodeIfPresent(String.self, forKey: .preferredDeviceName) ?? "LS24A600U"
        healthCheckIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .healthCheckIntervalSeconds) ?? 30
        postWakeDelaySeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .postWakeDelaySeconds) ?? 8
        healthCheckTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .healthCheckTimeoutSeconds) ?? 3
        minimumRecoveryCooldownSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .minimumRecoveryCooldownSeconds) ?? 30
        continuousRecovery = try container.decodeIfPresent(Bool.self, forKey: .continuousRecovery) ?? true
        recoveryWindowSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .recoveryWindowSeconds) ?? 300
    }

    static var configurationPath: String {
        if let override = ProcessInfo.processInfo.environment["DISPLAYAUDIOFIX_CONFIG"], !override.isEmpty {
            return override
        }
        return "/Library/Application Support/DisplayAudioFix/config.json"
    }

    static func load() -> Configuration {
        var value = Configuration()
        let url = URL(fileURLWithPath: configurationPath)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Configuration.self, from: data) {
            value = decoded
        }
        if let name = ProcessInfo.processInfo.environment["DISPLAYAUDIOFIX_PREFERRED_DEVICE"], !name.isEmpty {
            value.preferredDeviceName = name
        }
        return value
    }
}

struct AudioDeviceInfo {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transportRawValue: UInt32
    let transport: String
    let sampleRate: Double
    let isDefaultOutput: Bool
    let isSystemOutput: Bool
    let isAlive: Bool?
    let isRunning: Bool?
    let outputChannels: Int

    var isDisplayAudio: Bool {
        transportRawValue == kAudioDeviceTransportTypeDisplayPort ||
        transportRawValue == kAudioDeviceTransportTypeHDMI
    }

    var isBuiltInOutput: Bool {
        transportRawValue == kAudioDeviceTransportTypeBuiltIn && outputChannels > 0
    }

    var isVirtual: Bool {
        transportRawValue == kAudioDeviceTransportTypeVirtual
    }
}

enum HealthStatus: Equatable, CustomStringConvertible {
    case healthy
    case startFailed(OSStatus)
    case timelineTimeout
    case deviceMissing
    case deviceNotRunning

    var description: String {
        switch self {
        case .healthy: return "HEALTHY"
        case .startFailed(let code): return "START_FAILED (\(formatOSStatus(code)))"
        case .timelineTimeout: return "TIMELINE_TIMEOUT"
        case .deviceMissing: return "DEVICE_MISSING"
        case .deviceNotRunning: return "DEVICE_NOT_RUNNING"
        }
    }
}

func formatOSStatus(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
        return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")' (\(status))"
    }
    return String(status)
}

struct PersistentState: Codable {
    var lastRecovery: Date?
    var recoveryTimestamps: [Date] = []
    var recoveryCountByDay: [String: Int] = [:]
    // The DisplayPort UID survives a CoreAudio restart even when a full HAL
    // device enumeration is temporarily blocked by another endpoint.
    var preferredDeviceUID: String?
}
