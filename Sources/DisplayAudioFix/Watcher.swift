import Foundation
import Darwin

final class Watcher {
    private let audio: CoreAudioManager
    private let checker: HealthChecker
    private let recovery: RecoveryManager
    private let config: Configuration
    private let logger = AppLogger.shared
    private let stateStore: StateStore
    private let workQueue = DispatchQueue(label: "com.displayaudiofix.recovery")
    private let streamBufferLock = NSLock()
    private let preferredUIDLock = NSLock()
    private var streamBuffer = ""
    private var logProcess: Process?
    private var powerMonitor: PowerMonitor?
    private var healthTimer: DispatchSourceTimer?
    private var instanceLock: Int32 = -1
    // A display reconnect can produce dozens of CoreAudio log lines. Keep one
    // delayed retry for the whole burst; otherwise each line schedules another
    // recovery and competes with BetterDisplay's own AudioQueue client.
    private var retryScheduled = false
    // CoreAudio can emit several lines for one failed start. Coalesce that burst
    // while leaving the periodic probe responsible for the next retry.
    private var lastLogRecoveryAt = Date.distantPast
    // Keep the last known endpoint identity even while CoreAudio temporarily
    // reports an empty device list. UID-only coreaudiod errors must still wake
    // the recovery path during that gap.
    private var lastPreferredUID: String?
    private var lastPreferredName: String?

    init(audio: CoreAudioManager, checker: HealthChecker, recovery: RecoveryManager, config: Configuration, stateStore: StateStore) {
        self.audio = audio
        self.checker = checker
        self.recovery = recovery
        self.config = config
        self.stateStore = stateStore
        let state = stateStore.load()
        self.lastPreferredUID = state.preferredDeviceUID
        self.lastPreferredName = state.activeDeviceName
    }

    func run() -> Never {
        guard acquireSingleInstance() else {
            logger.log("watch daemon skipped; another DisplayAudioFix watcher is already running")
            exit(0)
        }
        logger.log("watch daemon started; preferred device: \(config.preferredDeviceName); active target: \(preferredName()); automatic physical-output switching: \(config.followActiveOutput)")
        startUnifiedLogStream()
        startPeriodicHealthChecks()
        powerMonitor = PowerMonitor { [weak self] in self?.schedulePostWakeCheck() }
        powerMonitor?.start()
        dispatchMain()
    }

    // The system LaunchDaemon and user LaunchAgent can otherwise both probe
    // and reset the same CoreAudio endpoint. A shared /tmp advisory lock works
    // across their different users without requiring another privileged API.
    private func acquireSingleInstance() -> Bool {
        let path = "/tmp/com.displayaudiofix.watch.lock"
        let descriptor = open(path, O_CREAT | O_RDWR, 0o666)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        instanceLock = descriptor
        return true
    }

    private func startUnifiedLogStream() {
        if let current = logProcess, current.isRunning {
            return
        }
        let predicate = #"process == "coreaudiod" AND (eventMessage CONTAINS[c] "could not establish a timeline" OR eventMessage CONTAINS[c] "1937010544" OR eventMessage CONTAINS[c] "StartIOThread" OR eventMessage CONTAINS[c] "is not running")"#
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--level", "info", "--predicate", predicate]
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.consumeLogText(text)
        }
        process.terminationHandler = { [weak self] process in
            if self?.logProcess === process {
                self?.logProcess = nil
            }
            self?.logger.log("unified log stream exited with status \(process.terminationStatus); restarting in 5 seconds")
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { self?.startUnifiedLogStream() }
        }
        do {
            try process.run()
            logProcess = process
        } catch {
            logger.log("failed to start unified log monitor: \(error)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.startUnifiedLogStream() }
        }
    }

    private func consumeLogText(_ text: String) {
        streamBufferLock.lock()
        streamBuffer.append(text)
        guard let lastNewline = streamBuffer.lastIndex(where: { $0.isNewline }) else {
            streamBufferLock.unlock()
            return
        }
        let complete = String(streamBuffer[..<streamBuffer.index(after: lastNewline)])
        streamBuffer = String(streamBuffer[streamBuffer.index(after: lastNewline)...])
        let lines = complete.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init)
        streamBufferLock.unlock()
        lines.forEach(handleLogLine)
    }

    private func handleLogLine(_ line: String) {
        let lower = line.lowercased()
        guard !lower.contains("filtering the log data") else { return }
        let hardTimelineFailure = lower.contains("could not establish a timeline")
        let deviceStopped = lower.contains("device") && lower.contains("is not running")
        let failedStart = lower.contains("startiothread") &&
            (lower.contains("failed to start") || lower.contains("1937010544"))
        // During a display reconnect CoreAudio can emit
        // `mIODisableCount != 0` while it is deliberately pausing an IO
        // context. That transition is not a failure; treating it as one can
        // restart coreaudiod in the middle of BetterDisplay's re-enumeration.
        guard hardTimelineFailure || deviceStopped || lower.contains("1937010544") || failedStart else { return }
        if let uid = observedUID(in: line) {
            rememberPreferredUID(uid)
        }
        guard shouldTreatAsDisplayFailure(logLine: lower) else {
            return
        }
        logger.log("CoreAudio failure detected: \(line)")
        workQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastLogRecoveryAt) >= 10 else { return }
            self.lastLogRecoveryAt = now
            self.performRecovery(trigger: "coreaudiod log event")
        }
    }

    private func shouldTreatAsDisplayFailure(logLine: String) -> Bool {
        let targetName = preferredName()
        let current = audio.boundedDefaultOutputDevice(timeout: 1.5)
        let preferred = audio.boundedPreferredDevice(
            named: targetName,
            stableUID: preferredUID(),
            followActiveOutput: config.followActiveOutput,
            timeout: 1.5
        )
        if let preferred, !preferred.uid.isEmpty {
            rememberPreferredDevice(preferred)
        }
        if let current, current.isPhysicalOutput { return true }
        if let current, current.name.caseInsensitiveCompare(targetName) == .orderedSame { return true }
        if let preferred, preferred.isDefaultOutput || preferred.isSystemOutput { return true }
        if let preferred, !preferred.uid.isEmpty && logLine.contains(preferred.uid.lowercased()) { return true }
        if let uid = preferredUID(), logLine.contains(uid) { return true }
        return logLine.contains(targetName.lowercased()) || logLine.contains(config.preferredDeviceName.lowercased())
    }

    private func startPeriodicHealthChecks() {
        // A stale config from an older build must not restore a long interval
        // that effectively disables continuous recovery. Keep the retry cadence
        // bounded to at most 30 seconds while honoring a larger minimum only
        // through a future explicit policy change.
        let interval = min(max(config.healthCheckIntervalSeconds, 30), 30)
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.healthCheckIfUseful(reason: "periodic health check") }
        timer.resume()
        healthTimer = timer
    }

    private func schedulePostWakeCheck() {
        workQueue.asyncAfter(deadline: .now() + max(config.postWakeDelaySeconds, 2)) { [weak self] in
            self?.healthCheckIfUseful(reason: "post-wake health check")
        }
    }

    private func healthCheckIfUseful(reason: String) {
        // Keep probing the preferred display even after a failed recovery has
        // selected the built-in fallback. Otherwise the fallback becomes a
        // permanent stop condition and the configured/active physical output
        // is never retried.
        let targetName = preferredName()
        guard let preferred = audio.boundedPreferredDevice(
            named: targetName,
            stableUID: preferredUID(),
            followActiveOutput: config.followActiveOutput,
            timeout: 1.5
        ) else {
            logger.log("\(reason): preferred device missing or CoreAudio enumeration timed out", alsoPrint: false)
            // A missing endpoint is itself a recovery condition. Waiting for a
            // future log line can deadlock forever when coreaudiod has stopped
            // publishing device events, so run the staged reset directly.
            if config.continuousRecovery {
                performRecovery(trigger: "\(reason) could not enumerate preferred device")
            } else {
                scheduleRetry(reason: "preferred device unavailable")
            }
            return
        }
        rememberPreferredDevice(preferred)
        let result = checker.test(device: preferred, timeout: config.healthCheckTimeoutSeconds, audible: false)
        if result == .healthy {
            retryScheduled = false
            if preferred.isDefaultOutput && preferred.isSystemOutput {
                logger.log("\(reason): HEALTHY", alsoPrint: false)
            } else {
                logger.log("\(reason): preferred device is healthy but not default; restoring it")
                do {
                    guard audio.boundedSetDefaultOutput(preferred, timeout: 2) else {
                        throw CoreAudioError.property("set default audio device", -1)
                    }
                    logger.log("\(reason): preferred device restored as default", alsoPrint: false)
                } catch {
                    logger.log("\(reason): healthy preferred device could not become default: \(error)")
                    performRecovery(trigger: "\(reason) could not select healthy preferred device")
                }
            }
            return
        }
        logger.log("\(reason): \(result)")
        if config.continuousRecovery || preferred.isDefaultOutput || preferred.isSystemOutput {
            performRecovery(trigger: "\(reason) returned \(result)")
        }
    }

    private func performRecovery(trigger: String) {
        let succeeded = recovery.recover(trigger: trigger)
        if !succeeded {
            scheduleRetry(reason: "recovery did not complete")
        }
    }

    private func scheduleRetry(reason: String) {
        guard !retryScheduled else { return }
        retryScheduled = true
        let compactReason = reason.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? "recovery retry"
        workQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.healthCheckIfUseful(reason: "retry after \(compactReason)")
        }
    }

    private func preferredUID() -> String? {
        preferredUIDLock.lock(); defer { preferredUIDLock.unlock() }
        return lastPreferredUID
    }

    private func preferredName() -> String {
        preferredUIDLock.lock(); defer { preferredUIDLock.unlock() }
        return lastPreferredName ?? config.preferredDeviceName
    }

    private func rememberPreferredDevice(_ device: AudioDeviceInfo) {
        let normalizedUID = device.uid.lowercased()
        preferredUIDLock.lock()
        let changed = lastPreferredUID != normalizedUID || lastPreferredName != device.name
        lastPreferredUID = normalizedUID.isEmpty ? lastPreferredUID : normalizedUID
        lastPreferredName = device.name
        preferredUIDLock.unlock()
        guard changed else { return }
        var state = stateStore.load()
        if !normalizedUID.isEmpty {
            state.preferredDeviceUID = normalizedUID
        }
        state.activeDeviceName = device.name
        state.activeDeviceIsDisplayAudio = device.isDisplayAudio
        stateStore.save(state)
    }

    private func rememberPreferredUID(_ uid: String) {
        let normalized = uid.lowercased()
        guard !normalized.isEmpty else { return }
        preferredUIDLock.lock()
        let changed = lastPreferredUID != normalized
        lastPreferredUID = normalized
        preferredUIDLock.unlock()
        guard changed else { return }
        var state = stateStore.load()
        state.preferredDeviceUID = normalized
        stateStore.save(state)
    }

    private func observedUID(in line: String) -> String? {
        for token in line.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "," || $0 == ":" }) {
            let value = String(token).trimmingCharacters(in: .punctuationCharacters)
            if let uuid = UUID(uuidString: value) {
                return uuid.uuidString.lowercased()
            }
        }
        return nil
    }
}
