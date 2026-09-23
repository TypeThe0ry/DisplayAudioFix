import Foundation

final class RecoveryManager {
    private struct BetterDisplaySession {
        let uid: String
    }

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

        // BetterDisplay can retain an AudioQueue/IO context across a display
        // reconnect. Quiesce it before making CoreAudio property calls: on the
        // affected failure path those calls can time out while its stale client
        // still owns the old DisplayPort I/O context.
        logger.log("recovery stage 1: pausing BetterDisplay before CoreAudio queries")
        let betterDisplaySession = stopBetterDisplayForRecovery()
        defer {
            if let betterDisplaySession {
                relaunchBetterDisplay(for: betterDisplaySession)
            }
        }

        logger.log("recovery stage 2: locating preferred output \(config.preferredDeviceName)")
        let preferredBefore = audio.boundedPreferredDevice(named: config.preferredDeviceName, timeout: 2)
        let stableUID = preferredBefore?.uid
        if preferredBefore == nil {
            // A transiently unqueryable endpoint is exactly what a wedged HAL
            // can look like. Do not abort before restarting coreaudiod.
            logger.log("preferred output is not enumerable yet; continuing with CoreAudio reset")
        } else if preferredBefore?.outputChannels == 0 {
            logger.log("preferred output currently reports no channels; continuing with CoreAudio reset")
        }

        logger.log("recovery stage 3: selecting built-in fallback when available")
        let fallback = audio.boundedBuiltInFallback(timeout: 2)
        if let fallback {
            do {
                try audio.setDefaultOutput(fallback)
                logger.log("switching temporary output to \(fallback.name)")
            } catch {
                // The fallback switch can fail for the same reason enumeration
                // failed. Still restart coreaudiod and retry the fallback after
                // it has rebuilt its device graph.
                logger.log("could not select fallback before CoreAudio reset: \(error); continuing")
            }
        } else {
            logger.log("built-in output is not enumerable yet; continuing with CoreAudio reset")
        }

        logger.log("recovery stage 4: restarting coreaudiod")
        let restart = ProcessRunner.run("/bin/launchctl", ["kickstart", "-kp", "system/com.apple.audio.coreaudiod"])
        guard restart.status == 0 else {
            logger.log("coreaudiod restart failed: \(restart.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            selectFreshFallback(named: fallback?.name)
            return false
        }

        logger.log("recovery stage 5: waiting for CoreAudio device enumeration")
        // Hot-switches can leave CoreAudio unresponsive for longer than the
        // original 15-second window. Poll in short bounded calls for up to a
        // minute so one blocked property query cannot wedge the watcher.
        let deadline = Date().addingTimeInterval(60)
        var restored: AudioDeviceInfo?
        var delay: TimeInterval = 0.5
        while Date() < deadline {
            if let candidate = audio.boundedPreferredDevice(named: config.preferredDeviceName, stableUID: stableUID, timeout: 1.5),
               candidate.outputChannels > 0, candidate.isAlive != false {
                restored = candidate
                break
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 1.5, 2.0)
        }
        guard let restored else {
            if let fallback {
                logger.log("preferred output did not reappear within 60 seconds; leaving \(fallback.name) selected")
            } else {
                logger.log("preferred output did not reappear within 60 seconds; selecting any available built-in output")
            }
            selectFreshFallback(named: fallback?.name)
            return false
        }
        logger.log("\(restored.name) rediscovered")

        logger.log("recovery stage 6: restoring \(restored.name) as default and system output")
        do {
            try audio.setDefaultOutput(restored)
        } catch {
            logger.log("failed to restore preferred output: \(error); leaving built-in output selected")
            selectFreshFallback(named: fallback?.name)
            return false
        }

        logger.log("recovery stage 6b: renegotiating \(restored.name) sample rate")
        renegotiateSampleRate(for: restored)

        logger.log("recovery stage 7: running silent playback health check")
        var result = checker.test(device: audio.boundedPreferredDevice(named: config.preferredDeviceName, stableUID: stableUID, timeout: 1.5), timeout: config.healthCheckTimeoutSeconds, audible: false)
        if result != .healthy {
            logger.log("post-recovery health check returned \(result); retrying once after 2 seconds")
            Thread.sleep(forTimeInterval: 2)
            if let fresh = audio.boundedPreferredDevice(named: config.preferredDeviceName, stableUID: stableUID, timeout: 1.5) {
                try? audio.setDefaultOutput(fresh)
                result = checker.test(device: fresh, timeout: config.healthCheckTimeoutSeconds, audible: false)
            } else {
                result = .deviceMissing
            }
        }
        guard result == .healthy else {
            if let fallback {
                logger.log("recovery unsuccessful (\(result)); leaving \(fallback.name) selected")
            } else {
                logger.log("recovery unsuccessful (\(result)); selecting any available built-in output")
            }
            selectFreshFallback(named: fallback?.name)
            return false
        }
        logger.log("silent health check successful")
        logger.log("recovery completed")
        return true
    }

    private func selectFreshFallback(named oldName: String?) {
        let namedFallback = oldName.flatMap { name in
            audio.boundedDevices(timeout: 1.5)?.first(where: { $0.name == name })
        }
        if let fresh = namedFallback ?? audio.boundedBuiltInFallback(timeout: 1.5) {
            try? audio.setDefaultOutput(fresh)
        }
    }

    private func stopBetterDisplayForRecovery() -> BetterDisplaySession? {
        let found = ProcessRunner.run("/usr/bin/pgrep", ["-x", "BetterDisplay"])
        guard let pid = found.output
            .split(whereSeparator: \.isNewline)
            .compactMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            .first else { return nil }
        let uidOutput = ProcessRunner.run("/bin/ps", ["-o", "uid=", "-p", String(pid)]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uidOutput.isEmpty, uidOutput != "0" else { return nil }
        let terminated = ProcessRunner.run("/bin/kill", ["-TERM", String(pid)]).status == 0
        guard terminated else {
            logger.log("BetterDisplay was detected but could not be stopped; continuing without app restart")
            return nil
        }
        logger.log("paused BetterDisplay before CoreAudio recovery")
        return BetterDisplaySession(uid: uidOutput)
    }

    private func relaunchBetterDisplay(for session: BetterDisplaySession) {
        let launched = ProcessRunner.run("/bin/launchctl", [
            "asuser", session.uid, "/usr/bin/open", "-b", "pro.betterdisplay.BetterDisplay"
        ])
        if launched.status == 0 {
            logger.log("restarted BetterDisplay after CoreAudio recovery")
        } else {
            logger.log("BetterDisplay restart failed: \(launched.output.trimmingCharacters(in: .whitespacesAndNewlines))")
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
