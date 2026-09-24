import CoreAudio
import Foundation

private final class DeviceListBox {
    var value: [AudioDeviceInfo] = []
}

private final class DeviceInfoBox {
    var value: AudioDeviceInfo?
}

private final class BoolBox {
    var value = false
}

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
    private let snapshotQueryLock = NSLock()
    private var snapshotQueriesInFlight = 0
    private let uidQueryLock = NSLock()
    private var uidQueriesInFlight = 0
    private let defaultWriteLock = NSLock()
    private var defaultWritesInFlight = 0
    private let rateWriteLock = NSLock()
    private var rateWritesInFlight = 0

    // CoreAudio calls cannot be cancelled once they enter the HAL. Permit a
    // small bounded number of replacement attempts after a timeout so one
    // permanently wedged worker does not make every later recovery return
    // DEVICE_MISSING or refuse to restore the default output.
    private let maxTimedOutWorkers = 3

    func devices() -> [AudioDeviceInfo] {
        devicesUnbounded()
    }

    /// CoreAudio property calls can themselves block while coreaudiod is
    /// wedged during a display hot-switch. Keep watcher/CLI control paths
    /// bounded so one stuck HAL call cannot permanently stop recovery.
    func boundedDevices(timeout: TimeInterval = 2) -> [AudioDeviceInfo]? {
        snapshotQueryLock.lock()
        guard snapshotQueriesInFlight < maxTimedOutWorkers else {
            snapshotQueryLock.unlock()
            return nil
        }
        snapshotQueriesInFlight += 1
        snapshotQueryLock.unlock()
        let semaphore = DispatchSemaphore(value: 0)
        let box = DeviceListBox()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                self?.snapshotQueryLock.lock()
                if let self, self.snapshotQueriesInFlight > 0 {
                    self.snapshotQueriesInFlight -= 1
                }
                self?.snapshotQueryLock.unlock()
                semaphore.signal()
            }
            box.value = self?.devicesUnbounded() ?? []
        }
        guard semaphore.wait(timeout: .now() + max(timeout, 0.1)) == .success else {
            return nil
        }
        return box.value
    }

    private func devicesUnbounded() -> [AudioDeviceInfo] {
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

        return ids.compactMap { deviceInfoUnbounded($0, defaultID: defaultID, systemID: systemID) }
    }

    private func deviceInfoUnbounded(_ id: AudioDeviceID, defaultID: AudioDeviceID, systemID: AudioDeviceID) -> AudioDeviceInfo? {
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
    }

    func defaultOutputDevice() -> AudioDeviceInfo? {
        devices().first(where: { $0.isDefaultOutput })
    }

    func boundedDefaultOutputDevice(timeout: TimeInterval = 2) -> AudioDeviceInfo? {
        guard let snapshot = boundedDevices(timeout: timeout) else { return nil }
        return snapshot.first(where: { $0.isDefaultOutput })
    }

    func preferredDevice(
        named name: String,
        stableUID: String? = nil,
        followActiveOutput: Bool = false
    ) -> AudioDeviceInfo? {
        let current = devices()
        return findPreferred(
            in: current,
            named: name,
            stableUID: stableUID,
            followActiveOutput: followActiveOutput
        )
    }

    func boundedPreferredDevice(
        named name: String,
        stableUID: String? = nil,
        followActiveOutput: Bool = false,
        timeout: TimeInterval = 2
    ) -> AudioDeviceInfo? {
        // A wedged unrelated endpoint can block the full device-list walk even
        // after an endpoint has reappeared. When following the active physical
        // output, inspect the snapshot first so a deliberate switch to another
        // monitor, USB DAC, Bluetooth speaker, or built-in output is adopted
        // instead of being overwritten by the previous UID.
        if followActiveOutput,
           let current = boundedDevices(timeout: timeout) {
            return findPreferred(
                in: current,
                named: name,
                stableUID: stableUID,
                followActiveOutput: true
            )
        }
        if let stableUID, !stableUID.isEmpty,
           let byUID = boundedDeviceForUID(stableUID, name: name, timeout: timeout) {
            return byUID
        }
        guard let current = boundedDevices(timeout: timeout) else { return nil }
        return findPreferred(
            in: current,
            named: name,
            stableUID: stableUID,
            followActiveOutput: followActiveOutput
        )
    }

    private func findPreferred(
        in current: [AudioDeviceInfo],
        named name: String,
        stableUID: String? = nil,
        followActiveOutput: Bool = false
    ) -> AudioDeviceInfo? {
        let physicalOutputs = current.filter {
            $0.isPhysicalOutput && $0.isAlive != false
        }

        // The current physical default is the user's active destination. This
        // handles switches among DisplayPort/HDMI monitors, USB/Thunderbolt
        // devices, Bluetooth speakers, and the Mac's built-in speakers.
        let activeOutput = physicalOutputs.first(where: \.isDefaultOutput)
            ?? physicalOutputs.first(where: \.isSystemOutput)
        if followActiveOutput,
           let active = activeOutput,
           !active.isBuiltInOutput {
            return active
        }

        if let stableUID, !stableUID.isEmpty,
           let byUID = current.first(where: {
               !$0.uid.isEmpty && $0.uid.caseInsensitiveCompare(stableUID) == .orderedSame
           }) {
            // A built-in endpoint may only be the temporary fallback from a
            // previous disconnect. If an external physical output is now
            // connected, resume external audio instead of locking onto the
            // fallback forever.
            if followActiveOutput, byUID.isBuiltInOutput,
               let external = physicalOutputs.first(where: { !$0.isBuiltInOutput }) {
                return external
            }
            return byUID
        }
        if let exact = current.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.outputChannels > 0
        }) {
            return exact
        }
        if let partial = physicalOutputs.first(where: {
            $0.name.localizedCaseInsensitiveContains(name)
        }) {
            return partial
        }

        // If the configured or remembered endpoint is gone, use another
        // connected physical output before virtual devices. Prefer an active
        // external device, then any external device, and finally built-in.
        if followActiveOutput {
            let external = physicalOutputs.filter { !$0.isBuiltInOutput }
            return external.first(where: { $0.isRunning == true })
                ?? external.first(where: { $0.isDefaultOutput || $0.isSystemOutput })
                ?? external.first
                ?? activeOutput
                ?? physicalOutputs.first(where: { $0.isRunning == true })
                ?? physicalOutputs.first
        }
        return nil
    }

    private func boundedDeviceForUID(_ uid: String, name: String, timeout: TimeInterval) -> AudioDeviceInfo? {
        uidQueryLock.lock()
        guard uidQueriesInFlight < maxTimedOutWorkers else { uidQueryLock.unlock(); return nil }
        uidQueriesInFlight += 1
        uidQueryLock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        let box = DeviceInfoBox()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                self?.uidQueryLock.lock()
                if let self, self.uidQueriesInFlight > 0 {
                    self.uidQueriesInFlight -= 1
                }
                self?.uidQueryLock.unlock()
                semaphore.signal()
            }
            guard let self, let id = self.deviceID(forUID: uid), id != AudioDeviceID(kAudioObjectUnknown) else { return }
            // Do not read a second property here. A stale endpoint can make
            // any per-device property call block forever even though the UID
            // translation succeeded. The AudioQueue probe below is the
            // authoritative liveness check, so return a conservative record
            // and let recovery validate it instead of wedging this worker.
            box.value = AudioDeviceInfo(
                id: id,
                name: name,
                uid: uid,
                transportRawValue: kAudioDeviceTransportTypeDisplayPort,
                transport: "DisplayPort",
                sampleRate: 48_000,
                isDefaultOutput: false,
                isSystemOutput: false,
                isAlive: true,
                isRunning: nil,
                outputChannels: 2
            )
        }
        guard semaphore.wait(timeout: .now() + max(timeout, 0.1)) == .success else {
            return nil
        }
        return box.value
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        let inputUID: CFString = uid as CFString
        var uidReference: Unmanaged<CFString>? = Unmanaged.passUnretained(inputUID)
        var outputID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uidReference) { inputPointer in
            withUnsafeMutablePointer(to: &outputID) { outputPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(inputPointer),
                    mInputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                    mOutputData: UnsafeMutableRawPointer(outputPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &translation)
            }
        }
        return status == noErr && outputID != AudioDeviceID(kAudioObjectUnknown) ? outputID : nil
    }

    func builtInFallback() -> AudioDeviceInfo? {
        let outputs = devices().filter(\.isBuiltInOutput)
        return outputs.first(where: {
            let lowered = $0.name.lowercased()
            return lowered.contains("macbook") || lowered.contains("built-in") || lowered.contains("internal")
        }) ?? outputs.first
    }

    func boundedBuiltInFallback(timeout: TimeInterval = 2) -> AudioDeviceInfo? {
        guard let outputs = boundedDevices(timeout: timeout)?.filter(\.isBuiltInOutput) else { return nil }
        return outputs.first(where: {
            let lowered = $0.name.lowercased()
            return lowered.contains("macbook") || lowered.contains("built-in") || lowered.contains("internal")
        }) ?? outputs.first
    }

    func setDefaultOutput(_ device: AudioDeviceInfo) throws {
        try setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    /// Bound writes as well as reads. During a display reconnect CoreAudio can
    /// block a setter while the endpoint is being torn down; recovery must
    /// still reach the coreaudiod restart stage instead of waiting forever.
    func boundedSetDefaultOutput(_ device: AudioDeviceInfo, timeout: TimeInterval = 2) -> Bool {
        defaultWriteLock.lock()
        guard defaultWritesInFlight < maxTimedOutWorkers else {
            defaultWriteLock.unlock()
            return false
        }
        defaultWritesInFlight += 1
        defaultWriteLock.unlock()
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                self?.defaultWriteLock.lock()
                if let self, self.defaultWritesInFlight > 0 {
                    self.defaultWritesInFlight -= 1
                }
                self?.defaultWriteLock.unlock()
                semaphore.signal()
            }
            if let self {
                box.value = (try? self.setDefaultOutput(device)) != nil
            }
        }
        guard semaphore.wait(timeout: .now() + max(timeout, 0.1)) == .success else { return false }
        return box.value
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

    func boundedSetNominalSampleRate(_ rate: Double, for device: AudioDeviceInfo, timeout: TimeInterval = 2) -> Bool {
        rateWriteLock.lock()
        guard rateWritesInFlight < maxTimedOutWorkers else {
            rateWriteLock.unlock()
            return false
        }
        rateWritesInFlight += 1
        rateWriteLock.unlock()
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                self?.rateWriteLock.lock()
                if let self, self.rateWritesInFlight > 0 {
                    self.rateWritesInFlight -= 1
                }
                self?.rateWriteLock.unlock()
                semaphore.signal()
            }
            if let self {
                box.value = (try? self.setNominalSampleRate(rate, for: device)) != nil
            }
        }
        guard semaphore.wait(timeout: .now() + max(timeout, 0.1)) == .success else { return false }
        return box.value
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
