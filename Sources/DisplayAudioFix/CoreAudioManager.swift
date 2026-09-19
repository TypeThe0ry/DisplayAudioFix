import CoreAudio
import Foundation

enum CoreAudioError: Error, CustomStringConvertible {
    case property(String, OSStatus)
    case noOutputDevice(String)

    var description: String {
        switch self {
        case .property(let action, let status): return "\(action): \(formatOSStatus(status))"
        case .noOutputDevice(let name): return "output device not found: \(name)"
        }
    }
}

final class CoreAudioManager {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func devices() -> [AudioDeviceInfo] {
        let defaultID = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let systemID = defaultDevice(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            let channelCount = outputChannelCount(id)
            guard channelCount > 0 else { return nil }
            let transportValue = uint32Property(id, kAudioDevicePropertyTransportType) ?? 0
            return AudioDeviceInfo(
                id: id,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Unknown",
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                transportRawValue: transportValue,
                transport: transportName(transportValue),
                sampleRate: float64Property(id, kAudioDevicePropertyNominalSampleRate) ?? 0,
                isDefaultOutput: id == defaultID,
                isSystemOutput: id == systemID,
                isAlive: uint32Property(id, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 },
                isRunning: uint32Property(id, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 },
                outputChannels: channelCount
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultOutputDevice() -> AudioDeviceInfo? {
        devices().first(where: { $0.isDefaultOutput })
    }

    func preferredDevice(named name: String, stableUID: String? = nil) -> AudioDeviceInfo? {
        let current = devices()
        if let exact = current.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        if let stableUID, !stableUID.isEmpty,
           let byUID = current.first(where: { $0.uid == stableUID }) {
            return byUID
        }
        return current.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
    }

    func builtInFallback() -> AudioDeviceInfo? {
        let outputs = devices().filter(\.isBuiltInOutput)
        return outputs.first(where: {
            let lowered = $0.name.lowercased()
            return lowered.contains("macbook") || lowered.contains("built-in") || lowered.contains("internal")
        }) ?? outputs.first
    }

    func setDefaultOutput(_ device: AudioDeviceInfo) throws {
        try setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    func setNominalSampleRate(_ rate: Double, for device: AudioDeviceInfo) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(rate)
        let status = AudioObjectSetPropertyData(
            device.id, &address, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &value
        )
        guard status == noErr else {
            throw CoreAudioError.property("set nominal sample rate", status)
        }
    }

    private func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &value) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return value
    }

    private func setDefaultDevice(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = id
        let status = AudioObjectSetPropertyData(
            systemObject, &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &mutableID
        )
        guard status == noErr else { throw CoreAudioError.property("set default audio device", status) }
    }

    private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func float64Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func outputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func transportName(_ value: UInt32) -> String {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default:
            let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
            let code = String(bytes: bytes, encoding: .ascii) ?? "unknown"
            return "Other (\(code))"
        }
    }
}
