import Darwin
import Foundation

final class RecoveryManager {
    private struct BetterDisplaySession {
        let uid: String
    }

    private let betterDisplayExecutable = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    private let audio: CoreAudioManager
    private let checker: HealthChecker
    private let config: Configuration
    private let stateStore: StateStore
    private let logger = AppLogger.shared
    private let lock = NSLock()
    private var inProgress = false
    // A failed recovery must not turn into a restart storm when CoreAudio has
    // lost the display endpoint or a third-party virtual driver is wedged.
    // Back off progressively, but never give up: a later health check can
    // reset the backoff as soon as a real physical output is healthy again.
    private var consecutiveFailures = 0
    private var nextRecoveryAllowedAt = Date.distantPast

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
        if now < nextRecoveryAllowedAt {
            let remaining = max(1, Int(ceil(nextRecoveryAllowedAt.timeIntervalSince(now))))
            lock.unlock()
            logger.log("recovery suppressed: adaptive backoff active; retrying in \(remaining)s (trigger: \(trigger))")
            return false
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
        guard let sharedLock = acquireSharedRecoveryLock() else {
            lock.lock(); inProgress = false; lock.unlock()
            logger.log("recovery skipped: another DisplayAudioFix repair is already running")
            return false
        }
        var recoverySucceeded = false
        defer {
            flock(sharedLock, LOCK_UN)
            close(sharedLock)
            lock.lock()
            inProgress = false
            if recoverySucceeded {
                consecutiveFailures = 0
                nextRecoveryAllowedAt = .distantPast
            } else {
                consecutiveFailures = min(consecutiveFailures + 1, 6)
                let base = max(config.minimumRecoveryCooldownSeconds, 30)
                let delay = min(base * pow(2, Double(max(0, consecutiveFailures - 1))), 300)
                nextRecoveryAllowedAt = Date().addingTimeInterval(delay)
            }
            let failures = consecutiveFailures
            let nextRetry = nextRecoveryAllowedAt
            lock.unlock()
            if !recoverySucceeded {
                let seconds = max(1, Int(ceil(nextRetry.timeIntervalSinceNow)))
                logger.log("recovery failed; adaptive backoff \(seconds)s (consecutive failures: \(failures))")
            }
        }
        recordAttempt()
        logger.log("recovery started (trigger: \(trigger))")

        let initialState = stateStore.load()
        var activeDeviceName = initialState.activeDeviceName ?? config.preferredDeviceName
        let knownUID = initialState.preferredDeviceUID
        // Keep the old behavior for an existing installation whose state file
        // predates generic output tracking: LS24A600U was a display endpoint,
        // so BetterDisplay still needs to be quiesced before the first repair.
        var activeDeviceIsDisplayAudio = initialState.activeDeviceIsDisplayAudio ?? true
        let initialTarget = audio.boundedPreferredDevice(
            named: activeDeviceName,
            stableUID: knownUID,
            followActiveOutput: config.followActiveOutput,
            timeout: 2
        )
        if let initialTarget {
            activeDeviceName = initialTarget.name
            activeDeviceIsDisplayAudio = initialTarget.isDisplayAudio
            rememberActiveTarget(initialTarget)
        }

        // BetterDisplay can retain an AudioQueue/IO context across a display
        // reconnect. Quiesce it only while the active target is a display
        // endpoint; USB, Bluetooth, built-in, and other speaker outputs do not
        // need BetterDisplay restarted.
        let stageOneDescription = activeDeviceIsDisplayAudio
            ? "pausing BetterDisplay before CoreAudio queries"
            : "preparing CoreAudio recovery for generic physical output"
        logger.log("recovery stage 1: \(stageOneDescription)")
        let betterDisplaySession = activeDeviceIsDisplayAudio ? stopBetterDisplayForRecovery() : nil
        var shouldReassertPreferredAfterBetterDisplay = false
        defer {
            if let betterDisplaySession {
                relaunchBetterDisplay(for: betterDisplaySession)
                if shouldReassertPreferredAfterBetterDisplay {
                    // BetterDisplay can reopen the display's audio client and
                    // leave the monitor's analog jack asleep even though the
                    // CoreAudio queue is healthy. Re-write the current DDC
                    // mute/volume values after the app is back, then assert
                    // the preferred endpoint once more. The values are read
                    // first so an intentional user mute or volume level is
                    // never overwritten.
                    if activeDeviceIsDisplayAudio {
                        reinitializeMonitorAudio(for: betterDisplaySession, deviceName: activeDeviceName)
                    }
                    reassertPreferredOutputAfterBetterDisplay(deviceName: activeDeviceName)
                }
            }
        }

        logger.log("recovery stage 2: locating active physical output \(activeDeviceName)")
        let preferredBefore = audio.boundedPreferredDevice(
            named: activeDeviceName,
            stableUID: knownUID,
            followActiveOutput: config.followActiveOutput,
            timeout: 2
        )
        var stableUID = preferredBefore?.uid ?? knownUID
        if let preferredBefore {
            activeDeviceName = preferredBefore.name
            activeDeviceIsDisplayAudio = preferredBefore.isDisplayAudio
            rememberActiveTarget(preferredBefore)
        }
        if let stableUID, !stableUID.isEmpty {
            var state = stateStore.load()
            state.preferredDeviceUID = stableUID.lowercased()
            state.activeDeviceName = activeDeviceName
            state.activeDeviceIsDisplayAudio = activeDeviceIsDisplayAudio
            stateStore.save(state)
        }
        if preferredBefore == nil {
            // A transiently unqueryable endpoint is exactly what a wedged HAL
            // can look like. Do not abort before restarting coreaudiod.
            logger.log("active physical output is not enumerable yet; continuing with CoreAudio reset")
        } else if preferredBefore?.outputChannels == 0 {
            logger.log("active physical output currently reports no channels; continuing with CoreAudio reset")
        }

        logger.log("recovery stage 3: selecting built-in fallback when available")
        let fallback = audio.boundedBuiltInFallback(timeout: 2)
        if let fallback {
            if audio.boundedSetDefaultOutput(fallback, timeout: 2) {
                logger.log("switching temporary output to \(fallback.name)")
            } else {
                // The fallback switch can fail for the same reason enumeration
                // failed. Still restart coreaudiod and retry the fallback after
                // it has rebuilt its device graph.
                logger.log("could not select fallback before CoreAudio reset; continuing")
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
            if let candidate = audio.boundedPreferredDevice(
                named: activeDeviceName,
                stableUID: stableUID,
                // The built-in output is deliberately selected as a temporary
                // fallback before coreaudiod restarts; do not mistake that
                // fallback for a user switch while waiting for the target.
                followActiveOutput: false,
                timeout: 1.5
            ),
               candidate.outputChannels > 0, candidate.isAlive != false {
                activeDeviceName = candidate.name
                activeDeviceIsDisplayAudio = candidate.isDisplayAudio
                if !candidate.uid.isEmpty {
                    stableUID = candidate.uid
                }
                rememberActiveTarget(candidate)
                restored = candidate
                break
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 1.5, 2.0)
        }
        guard let restored else {
            if let fallback {
                logger.log("active physical output did not reappear within 60 seconds; leaving \(fallback.name) selected")
            } else {
                logger.log("active physical output did not reappear within 60 seconds; selecting any available built-in output")
            }
            selectFreshFallback(named: fallback?.name)
            return false
        }
        logger.log("\(restored.name) rediscovered")

        logger.log("recovery stage 6: restoring \(restored.name) as default and system output")
        guard audio.boundedSetDefaultOutput(restored, timeout: 2) else {
            logger.log("failed to restore active physical output within timeout; leaving built-in output selected")
            selectFreshFallback(named: fallback?.name)
            return false
        }

        logger.log("recovery stage 6b: renegotiating \(restored.name) sample rate")
        renegotiateSampleRate(for: restored)

        logger.log("recovery stage 7: running silent playback health check")
        var result = checker.test(
            device: audio.boundedPreferredDevice(
                named: activeDeviceName,
                stableUID: stableUID,
                followActiveOutput: false,
                timeout: 1.5
            ),
            timeout: config.healthCheckTimeoutSeconds,
            audible: false
        )
        if result != .healthy {
            logger.log("post-recovery health check returned \(result); retrying once after 2 seconds")
            Thread.sleep(forTimeInterval: 2)
            if let fresh = audio.boundedPreferredDevice(
                named: activeDeviceName,
                stableUID: stableUID,
                followActiveOutput: false,
                timeout: 1.5
            ) {
                activeDeviceName = fresh.name
                activeDeviceIsDisplayAudio = fresh.isDisplayAudio
                if !fresh.uid.isEmpty {
                    stableUID = fresh.uid
                }
                rememberActiveTarget(fresh)
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
        var finalState = stateStore.load()
        finalState.activeDeviceName = activeDeviceName
        finalState.activeDeviceIsDisplayAudio = activeDeviceIsDisplayAudio
        if let stableUID, !stableUID.isEmpty {
            finalState.preferredDeviceUID = stableUID.lowercased()
        }
        stateStore.save(finalState)
        shouldReassertPreferredAfterBetterDisplay = true
        recoverySucceeded = true
        return true
    }

    /// A healthy, real output means the system is no longer in a recovery
    /// storm. Clear the adaptive delay so a newly connected monitor is picked
    /// up promptly instead of waiting for the previous failure backoff.
    func noteHealthyOutput() {
        lock.lock()
        consecutiveFailures = 0
        nextRecoveryAllowedAt = .distantPast
        lock.unlock()
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
        let pids = found.output
            .split(whereSeparator: \.isNewline)
            .compactMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        guard !pids.isEmpty else { return nil }
        var sessionUID: String?
        var terminatedPIDs: [Int32] = []
        for pid in pids {
            let uidOutput = ProcessRunner.run("/bin/ps", ["-o", "uid=", "-p", String(pid)]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uidOutput.isEmpty, uidOutput != "0" else { continue }
            sessionUID = sessionUID ?? uidOutput
            if ProcessRunner.run("/bin/kill", ["-TERM", String(pid)]).status == 0 {
                terminatedPIDs.append(pid)
            }
        }
        guard let uid = sessionUID, !terminatedPIDs.isEmpty else {
            logger.log("BetterDisplay was detected but could not be stopped; continuing without app restart")
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let stillRunning = terminatedPIDs.contains {
                ProcessRunner.run("/bin/kill", ["-0", String($0)]).status == 0
            }
            if !stillRunning { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let stillRunning = terminatedPIDs.contains {
            ProcessRunner.run("/bin/kill", ["-0", String($0)]).status == 0
        }
        if stillRunning {
            // A wedged BetterDisplay client is the failure mode this recovery
            // is meant to contain. Escalate only the non-root processes that
            // we already identified as BetterDisplay after a graceful TERM;
            // leaving a hung client alive would keep the stale DisplayPort
            // AudioQueue attached and make the next reconnect fail again.
            logger.log("BetterDisplay did not exit within 5 seconds; escalating to SIGKILL")
            for pid in terminatedPIDs {
                if ProcessRunner.run("/bin/kill", ["-0", String(pid)]).status == 0 {
                    _ = ProcessRunner.run("/bin/kill", ["-KILL", String(pid)])
                }
            }
            let hardDeadline = Date().addingTimeInterval(2)
            while Date() < hardDeadline {
                let alive = terminatedPIDs.contains {
                    ProcessRunner.run("/bin/kill", ["-0", String($0)]).status == 0
                }
                if !alive { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            let stillAliveAfterKill = terminatedPIDs.contains {
                ProcessRunner.run("/bin/kill", ["-0", String($0)]).status == 0
            }
            guard !stillAliveAfterKill else {
                logger.log("BetterDisplay could not be terminated; continuing without relaunch")
                return nil
            }
        }
        logger.log("paused BetterDisplay before CoreAudio recovery")
        return BetterDisplaySession(uid: uid)
    }

    private func relaunchBetterDisplay(for session: BetterDisplaySession) {
        let launched = ProcessRunner.run("/bin/launchctl", [
            "asuser", session.uid, "/usr/bin/open", "-b", "pro.betterdisplay.BetterDisplay"
        ])
        if launched.status == 0 {
            logger.log("restarted BetterDisplay after CoreAudio recovery")
            // LaunchServices returns before the app has recreated its DDC and
            // audio controllers. Give it a short bounded startup window
            // before issuing the hardware audio reinitialization below.
            Thread.sleep(forTimeInterval: 1.5)
        } else {
            logger.log("BetterDisplay restart failed: \(launched.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func reinitializeMonitorAudio(for session: BetterDisplaySession, deviceName: String) {
        guard FileManager.default.isExecutableFile(atPath: betterDisplayExecutable) else {
            logger.log("BetterDisplay audio reinitialization skipped: executable not found")
            return
        }

        let baseArguments = ["asuser", session.uid, betterDisplayExecutable]
        guard let muted = readBetterDisplayMuteState(baseArguments: baseArguments, deviceName: deviceName) else {
            logger.log("BetterDisplay audio reinitialization skipped: could not read monitor mute state")
            return
        }

        // A reconnect can leave a monitor's DDC mute bit latched even though
        // CoreAudio reports a healthy queue. Clear that stale mute bit during
        // a successful display recovery. BetterDisplay maps this command to
        // the display's DDC mute controller; the following volume write
        // restores the current level instead of changing it.
        if muted {
            logger.log("monitor mute was on after reconnect; clearing stale DDC mute")
        }

        let muteWrite = ProcessRunner.run("/bin/launchctl", baseArguments + [
            "set", "-nameLike=\(deviceName)", "-mute=off"
        ], timeout: 4)
        guard muteWrite.status == 0 else {
            logger.log("monitor DDC mute reinitialization failed: \(muteWrite.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }

        if let volume = readBetterDisplayVolume(baseArguments: baseArguments, deviceName: deviceName),
           volume >= 0, volume <= 1 {
            let volumeValue = String(format: "%.4f", volume)
            let volumeWrite = ProcessRunner.run("/bin/launchctl", baseArguments + [
                "set", "-nameLike=\(deviceName)", "-volume=\(volumeValue)"
            ], timeout: 4)
            if volumeWrite.status == 0 {
                logger.log("reinitialized monitor DDC audio path (mute=unmuted, volume=\(volumeValue))")
            } else {
                logger.log("monitor DDC volume reinitialization failed: \(volumeWrite.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } else {
            logger.log("reinitialized monitor DDC mute state; volume read was unavailable")
        }
    }

    private func readBetterDisplayMuteState(baseArguments: [String], deviceName: String) -> Bool? {
        for attempt in 0..<3 {
            let result = ProcessRunner.run("/bin/launchctl", baseArguments + [
                "get", "-nameLike=\(deviceName)", "-mute", "-value"
            ], timeout: 4)
            if result.status == 0 {
                let value = result.output.lowercased()
                if value.contains("off") { return false }
                if value.contains("on") { return true }
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return nil
    }

    private func readBetterDisplayVolume(baseArguments: [String], deviceName: String) -> Double? {
        for attempt in 0..<3 {
            let result = ProcessRunner.run("/bin/launchctl", baseArguments + [
                "get", "-nameLike=\(deviceName)", "-volume", "-value", "-min", "-max"
            ], timeout: 4)
            if result.status == 0 {
                for line in result.output.split(whereSeparator: \.isNewline) {
                    let token = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let token, let value = Double(token) {
                        return value
                    }
                }
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return nil
    }

    private func reassertPreferredOutputAfterBetterDisplay(deviceName: String) {
        let state = stateStore.load()
        guard let preferred = audio.boundedPreferredDevice(
            named: deviceName,
            stableUID: state.preferredDeviceUID,
            followActiveOutput: false,
            timeout: 2
        ) else {
            logger.log("preferred output could not be re-enumerated after BetterDisplay relaunch")
            return
        }
        guard audio.boundedSetDefaultOutput(preferred, timeout: 2) else {
            logger.log("preferred output could not be reasserted after BetterDisplay relaunch")
            return
        }
        logger.log("reasserted \(preferred.name) as default output after BetterDisplay relaunch")
    }

    private func renegotiateSampleRate(for device: AudioDeviceInfo) {
        // On macOS 27.0 the Samsung DP endpoint can remain enumerated while its
        // 48 kHz I/O context is wedged. A documented nominal-rate property
        // change forces CoreAudio to rebuild that context without touching
        // display settings. Restore the original rate before probing playback.
        let original = device.sampleRate > 0 ? device.sampleRate : 48_000
        let alternate: Double = abs(original - 44_100) < 1 ? 48_000.0 : 44_100.0
        if audio.boundedSetNominalSampleRate(alternate, for: device, timeout: 2) {
            Thread.sleep(forTimeInterval: 0.5)
            guard audio.boundedSetNominalSampleRate(original, for: device, timeout: 2) else {
                logger.log("sample-rate renegotiation restore timed out; continuing with playback probe")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
            let alternateText = String(format: "%.0f", alternate)
            let originalText = String(format: "%.0f", original)
            logger.log("sample-rate renegotiation completed (\(alternateText) -> \(originalText) Hz)")
        } else {
            logger.log("sample-rate renegotiation unavailable; continuing with playback probe")
        }
    }

    private func acquireSharedRecoveryLock() -> Int32? {
        let descriptor = open("/tmp/com.displayaudiofix.recovery.lock", O_CREAT | O_RDWR, 0o666)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func rememberActiveTarget(_ device: AudioDeviceInfo) {
        var state = stateStore.load()
        state.activeDeviceName = device.name
        state.activeDeviceIsDisplayAudio = device.isDisplayAudio
        if !device.uid.isEmpty {
            state.preferredDeviceUID = device.uid.lowercased()
        }
        stateStore.save(state)
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
