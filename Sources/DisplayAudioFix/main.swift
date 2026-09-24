import Darwin
import Foundation

let config = Configuration.load()
let audio = CoreAudioManager()
let checker = HealthChecker()
let stateStore = StateStore()
let recovery = RecoveryManager(audio: audio, checker: checker, config: config, stateStore: stateStore)

func usage() -> Never {
    print("""
    DisplayAudioFix
    Usage: displayaudiofix <command> [options]

      status                 concise device, health, daemon, and recovery status
      devices                enumerate CoreAudio output devices
      test [--audible]       run a bounded silent (or quiet audible) playback probe
      restore                select the preferred output after a successful probe
      set-rate <hz>          set the preferred device nominal sample rate
      repair                 run staged recovery (uses sudo when needed)
      watch                  monitor CoreAudio and recover automatically
      logs [--follow]        show the DisplayAudioFix log
      install                install and start the LaunchDaemon (uses sudo)
      uninstall              remove the LaunchDaemon and binary (keeps config/logs)
    """)
    exit(2)
}

func boolText(_ value: Bool?) -> String {
    value.map { $0 ? "yes" : "no" } ?? "unknown"
}

func daemonStatus() -> String {
    let uid = String(getuid())
    let systemRunning = ProcessRunner.run("/bin/launchctl", ["print", "system/\(Installer.label)"]).status == 0
    let userRunning = ProcessRunner.run("/bin/launchctl", ["print", "gui/\(uid)/com.displayaudiofix.agent"]).status == 0
    if systemRunning && userRunning { return "running (system LaunchDaemon + user continuous LaunchAgent)" }
    if systemRunning { return "running (system LaunchDaemon)" }
    if userRunning { return "running (user LaunchAgent; no coreaudiod restart privilege)" }
    return "not running"
}

func relativeTime(_ date: Date?) -> String {
    guard let date else { return "never" }
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m ago" }
    return "\(seconds / 86_400)d ago"
}

func todayKey() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

func commandStatus() {
    let state = stateStore.load()
    let preferred = audio.boundedPreferredDevice(
        named: config.preferredDeviceName,
        stableUID: state.preferredDeviceUID,
        timeout: 2
    )
    let current = audio.boundedDefaultOutputDevice(timeout: 2)
    let health: HealthStatus
    if let preferred {
        health = checker.test(device: preferred, timeout: config.healthCheckTimeoutSeconds, audible: false)
    } else {
        health = .deviceMissing
    }
    let version = ProcessRunner.run("/usr/bin/sw_vers", ["-productVersion"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    let build = ProcessRunner.run("/usr/bin/sw_vers", ["-buildVersion"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    print("""
    DisplayAudioFix
    macOS: \(version) (\(build))

    Preferred device:
      \(config.preferredDeviceName)\(preferred == nil ? " (not connected)" : "")

    Current default:
      \(current?.name ?? "none")

    Transport:
      \(current?.transport ?? "unknown")

    Sample rate:
      \(current.map { String(format: "%.0f Hz", $0.sampleRate) } ?? "unknown")

    Output path:
      \(current?.isDisplayAudio == true ? "DisplayPort digital stream; final volume is controlled by the monitor/headphone sink" : "CoreAudio software-controlled output")

    Health:
      \(health)

    Daemon:
      \(daemonStatus())

    Last recovery:
      \(relativeTime(state.lastRecovery))

    Recovery count today:
      \(state.recoveryCountByDay[todayKey(), default: 0])
    """)
}

func commandDevices() {
    guard let devices = audio.boundedDevices(timeout: 3) else {
        print("CoreAudio device enumeration timed out; coreaudiod may be restarting.")
        return
    }
    guard !devices.isEmpty else {
        print("No CoreAudio output devices found.")
        return
    }
    for device in devices {
        var roles: [String] = []
        if device.isDefaultOutput { roles.append("default") }
        if device.isSystemOutput { roles.append("system") }
        if device.isBuiltInOutput { roles.append("built-in") }
        if device.isDisplayAudio { roles.append("display-audio") }
        if device.isVirtual { roles.append("virtual") }
        print("""
        \(device.name)\(roles.isEmpty ? "" : " [\(roles.joined(separator: ", "))]")
          UID: \(device.uid.isEmpty ? "unknown" : device.uid)
          Transport: \(device.transport)
          Sample rate: \(String(format: "%.0f Hz", device.sampleRate))
          Alive: \(boolText(device.isAlive))
          Running: \(boolText(device.isRunning))
          Output channels: \(device.outputChannels)
        \(device.isDisplayAudio ? "  Volume: controlled by the display/headphone sink (macOS scalar/mute is unavailable)" : "")
        """)
    }
}

func commandTest(audible: Bool) -> Int32 {
    let target = audio.boundedPreferredDevice(
        named: config.preferredDeviceName,
        stableUID: stateStore.load().preferredDeviceUID,
        timeout: 2
    ) ?? audio.boundedDefaultOutputDevice(timeout: 2)
    print("Testing \(target?.name ?? config.preferredDeviceName)\(audible ? " with a 0.8s 880 Hz listening tone" : " with silence")...")
    let result = checker.test(device: target, timeout: config.healthCheckTimeoutSeconds, audible: audible)
    print(result)
    return result == .healthy ? 0 : 1
}

func commandRestore() -> Int32 {
    guard let preferred = audio.boundedPreferredDevice(
        named: config.preferredDeviceName,
        stableUID: stateStore.load().preferredDeviceUID,
        timeout: 2
    ) else {
        fputs("preferred output is not currently enumerated\n", stderr)
        return 1
    }
    let result = checker.test(device: preferred, timeout: config.healthCheckTimeoutSeconds, audible: false)
    guard result == .healthy else {
        fputs("preferred output failed health check: \(result)\n", stderr)
        return 1
    }
    do {
        try audio.setDefaultOutput(preferred)
        print("Restored \(preferred.name) as default and system output")
        print("HEALTHY")
        return 0
    } catch {
        fputs("failed to restore preferred output: \(error)\n", stderr)
        return 1
    }
}

func commandSetRate(_ value: String?) -> Never {
    guard let value, let rate = Double(value), rate > 0,
          let preferred = audio.preferredDevice(named: config.preferredDeviceName) else {
        fputs("usage: displayaudiofix set-rate <positive-hz>\n", stderr)
        exit(2)
    }
    do {
        try audio.setNominalSampleRate(rate, for: preferred)
        let formattedRate = String(format: "%.0f Hz", rate)
        print("Set \(preferred.name) nominal sample rate to \(formattedRate)")
        exit(0)
    } catch {
        fputs("failed to set nominal sample rate: \(error)\n", stderr)
        exit(1)
    }
}

func commandRepair() -> Never {
    if geteuid() != 0 {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let result = ProcessRunner.run("/usr/bin/sudo", [executable, "repair"], passthrough: true)
        exit(result.status)
    }
    exit(recovery.recover(trigger: "manual repair", bypassRateLimit: true) ? 0 : 1)
}

func commandLogs(follow: Bool) -> Never {
    let systemPath = AppLogger.systemLogPath
    let userPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DisplayAudioFix/displayaudiofix.log").path
    let path = FileManager.default.fileExists(atPath: systemPath) ? systemPath : userPath
    let args = follow ? ["-n", "100", "-f", path] : ["-n", "100", path]
    let result = ProcessRunner.run("/usr/bin/tail", args, passthrough: true)
    exit(result.status)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
switch command {
case "status": commandStatus()
case "devices": commandDevices()
case "test": exit(commandTest(audible: arguments.contains("--audible")))
case "restore": exit(commandRestore())
case "set-rate": commandSetRate(arguments.dropFirst().first)
case "repair": commandRepair()
case "watch":
    let watcher = Watcher(audio: audio, checker: checker, recovery: recovery, config: config, stateStore: stateStore)
    watcher.run()
case "logs": commandLogs(follow: arguments.contains("--follow"))
case "install":
    if geteuid() == 0 { Installer.install() } else { Installer.install() }
case "uninstall":
    if geteuid() == 0 { Installer.uninstall() } else { Installer.uninstall() }
case "help", "--help", "-h": usage()
default: usage()
}
