import Foundation

final class Watcher {
    private let audio: CoreAudioManager
    private let checker: HealthChecker
    private let recovery: RecoveryManager
    private let config: Configuration
    private let logger = AppLogger.shared
    private let workQueue = DispatchQueue(label: "com.displayaudiofix.recovery")
    private let streamBufferLock = NSLock()
    private var streamBuffer = ""
    private var logProcess: Process?
    private var powerMonitor: PowerMonitor?
    private var healthTimer: DispatchSourceTimer?
    // CoreAudio can emit several lines for one failed start. Coalesce that burst
    // while leaving the periodic probe responsible for the next retry.
    private var lastLogRecoveryAt = Date.distantPast

    init(audio: CoreAudioManager, checker: HealthChecker, recovery: RecoveryManager, config: Configuration) {
        self.audio = audio
        self.checker = checker
        self.recovery = recovery
        self.config = config
    }

    func run() -> Never {
        logger.log("watch daemon started; preferred device: \(config.preferredDeviceName)")
        startUnifiedLogStream()
        startPeriodicHealthChecks()
        powerMonitor = PowerMonitor { [weak self] in self?.schedulePostWakeCheck() }
        powerMonitor?.start()
        dispatchMain()
    }

    private func startUnifiedLogStream() {
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
        guard lower.contains("could not establish a timeline") ||
                lower.contains("1937010544") ||
                lower.contains("startiothread") ||
                (lower.contains("device") && lower.contains("is not running")) else { return }
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
        let current = audio.defaultOutputDevice()
        let preferred = audio.preferredDevice(named: config.preferredDeviceName)
        if let current, current.isDisplayAudio { return true }
        if let current, current.name.caseInsensitiveCompare(config.preferredDeviceName) == .orderedSame { return true }
        if let preferred, preferred.isDefaultOutput || preferred.isSystemOutput { return true }
        if let preferred, !preferred.uid.isEmpty && logLine.contains(preferred.uid.lowercased()) { return true }
        return logLine.contains(config.preferredDeviceName.lowercased())
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
        // permanent stop condition and LS24A600U is never retried.
        guard let preferred = audio.preferredDevice(named: config.preferredDeviceName) else {
            logger.log("\(reason): preferred device missing", alsoPrint: false)
            return
        }
        let result = checker.test(device: preferred, timeout: config.healthCheckTimeoutSeconds, audible: false)
        if result == .healthy {
            if preferred.isDefaultOutput && preferred.isSystemOutput {
                logger.log("\(reason): HEALTHY", alsoPrint: false)
            } else {
                logger.log("\(reason): preferred device is healthy but not default; restoring it")
                do {
                    try audio.setDefaultOutput(preferred)
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
        _ = recovery.recover(trigger: trigger)
    }
}
