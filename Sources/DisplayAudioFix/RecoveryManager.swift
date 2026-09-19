import Foundation

final class RecoveryManager {
    private let audio: CoreAudioManager
    private let checker: HealthChecker
    private let config: Configuration
    private let stateStore: StateStore
    private let logger = AppLogger.shared
    private let lock = NSLock()
    private var inProgress = false

    init(audio: CoreAudioManager, checker: HealthChecker, config: Configuration, stateStore: StateStore) {
        self.audio = audio
        self.checker = checker
        self.config = config
        self.stateStore = stateStore
    }

    func mayRecover(trigger: String) -> Bool {
        lock.lock()
        guard !inProgress else { lock.unlock(); return false }
        var state = stateStore.load()
        let now = Date()
        state.recoveryTimestamps = state.recoveryTimestamps.filter {
            now.timeIntervalSince($0) < config.recoveryWindowSeconds
        }
        if let last = state.lastRecovery,
           now.timeIntervalSince(last) < config.minimumRecoveryCooldownSeconds {
            lock.unlock()
            logger.log("recovery suppressed: \(Int(config.minimumRecoveryCooldownSeconds))-second cooldown active (trigger: \(trigger))")
            return false
        }
        // Do not impose a window-wide attempt cap. A display can remain broken
        // for longer than the recovery window, and the watcher must continue to
        // retry until a real playback probe succeeds. The cooldown above keeps
        // retries serialized and prevents a tight loop.
        inProgress = true
        lock.unlock()
        return true
    }

    @discardableResult
    func recover(trigger: String, bypassRateLimit: Bool = false) -> Bool {
        if !bypassRateLimit && !mayRecover(trigger: trigger) { return false }
        if bypassRateLimit {
            lock.lock()
            guard !inProgress else { lock.unlock(); return false }
            inProgress = true
            lock.unlock()
        }
        defer {
            lock.lock(); inProgress = false; lock.unlock()
        }
        recordAttempt()
        logger.log("recovery started (trigger: \(trigger))")

        logger.log("recovery stage 1: locating preferred output \(config.preferredDeviceName)")
        guard let preferredBefore = audio.preferredDevice(named: config.preferredDeviceName) else {
            logger.log("recovery failed: preferred device is missing")
            return false
        }
        let stableUID = preferredBefore.uid
        guard preferredBefore.outputChannels > 0 else {
            logger.log("recovery failed: preferred device has no output channels")
            return false
        }

        logger.log("recovery stage 2: selecting built-in fallback")
        guard let fallback = audio.builtInFallback() else {
            logger.log("recovery failed: no built-in output device found")
            return false
        }
        do {
            try audio.setDefaultOutput(fallback)
            logger.log("switching temporary output to \(fallback.name)")
        } catch {
            logger.log("recovery failed while selecting fallback: \(error)")
            return false
        }

        logger.log("recovery stage 3: restarting coreaudiod")
        let restart = ProcessRunner.run("/bin/launchctl", ["kickstart", "-kp", "system/com.apple.audio.coreaudiod"])
        guard restart.status == 0 else {
            logger.log("coreaudiod restart failed: \(restart.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        }

        logger.log("recovery stage 4: waiting for CoreAudio device enumeration")
        let deadline = Date().addingTimeInterval(15)
        var restored: AudioDeviceInfo?
        var delay: TimeInterval = 0.5
        while Date() < deadline {
            if let candidate = audio.preferredDevice(named: config.preferredDeviceName, stableUID: stableUID),
               candidate.outputChannels > 0, candidate.isAlive != false {
                restored = candidate
                break
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 1.5, 2.0)
        }
        guard let restored else {
            logger.log("preferred output did not reappear within 15 seconds; leaving \(fallback.name) selected")
            selectFreshFallback(named: fallback.name)
            return false
        }
        logger.log("\(restored.name) rediscovered")

        logger.log("recovery stage 5: restoring \(restored.name) as default and system output")
        do {
            try audio.setDefaultOutput(restored)
        } catch {
            logger.log("failed to restore preferred output: \(error); leaving built-in output selected")
            selectFreshFallback(named: fallback.name)
            return false
        }

        logger.log("recovery stage 5b: renegotiating \(restored.name) sample rate")
        renegotiateSampleRate(for: restored)

        logger.log("recovery stage 6: running silent playback health check")
        var result = checker.test(device: audio.preferredDevice(named: config.preferredDeviceName, stableUID: stableUID), timeout: config.healthCheckTimeoutSeconds, audible: false)
        if result != .healthy {
            logger.log("post-recovery health check returned \(result); retrying once after 2 seconds")
            Thread.sleep(forTimeInterval: 2)
            if let fresh = audio.preferredDevice(named: config.preferredDeviceName, stableUID: stableUID) {
                try? audio.setDefaultOutput(fresh)
                result = checker.test(device: fresh, timeout: config.healthCheckTimeoutSeconds, audible: false)
            } else {
                result = .deviceMissing
            }
        }
        guard result == .healthy else {
            logger.log("recovery unsuccessful (\(result)); leaving \(fallback.name) selected")
            selectFreshFallback(named: fallback.name)
            return false
        }
        logger.log("silent health check successful")
        logger.log("recovery completed")
        return true
    }

    private func selectFreshFallback(named oldName: String) {
        if let fresh = audio.devices().first(where: { $0.name == oldName }) ?? audio.builtInFallback() {
            try? audio.setDefaultOutput(fresh)
        }
    }

    private func renegotiateSampleRate(for device: AudioDeviceInfo) {
        // On macOS 27.0 the Samsung DP endpoint can remain enumerated while its
        // 48 kHz I/O context is wedged. A documented nominal-rate property
        // change forces CoreAudio to rebuild that context without touching
        // display settings. Restore the original rate before probing playback.
        let original = device.sampleRate > 0 ? device.sampleRate : 48_000
        let alternate: Double = abs(original - 44_100) < 1 ? 48_000.0 : 44_100.0
        do {
            try audio.setNominalSampleRate(alternate, for: device)
            Thread.sleep(forTimeInterval: 0.5)
            try audio.setNominalSampleRate(original, for: device)
            Thread.sleep(forTimeInterval: 0.5)
            let alternateText = String(format: "%.0f", alternate)
            let originalText = String(format: "%.0f", original)
            logger.log("sample-rate renegotiation completed (\(alternateText) -> \(originalText) Hz)")
        } catch {
            logger.log("sample-rate renegotiation unavailable: \(error); continuing with playback probe")
        }
    }

    private func recordAttempt() {
        var state = stateStore.load()
        let now = Date()
        state.recoveryTimestamps = state.recoveryTimestamps.filter {
            now.timeIntervalSince($0) < config.recoveryWindowSeconds
        }
        state.lastRecovery = now
        state.recoveryTimestamps.append(now)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let key = dayFormatter.string(from: now)
        state.recoveryCountByDay[key, default: 0] += 1
        if state.recoveryCountByDay.count > 14 {
            let keep = state.recoveryCountByDay.keys.sorted().suffix(14)
            state.recoveryCountByDay = Dictionary(uniqueKeysWithValues: keep.compactMap { key in
                state.recoveryCountByDay[key].map { (key, $0) }
            })
        }
        stateStore.save(state)
    }
}
