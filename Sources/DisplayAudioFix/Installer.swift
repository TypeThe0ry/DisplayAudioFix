import Darwin
import Foundation

enum Installer {
    static let label = "com.displayaudiofix.daemon"
    static let binary = "/usr/local/bin/displayaudiofix"
    static let plist = "/Library/LaunchDaemons/\(label).plist"

    static func install() -> Never {
        ensureRoot(command: "install")
        let manager = FileManager.default
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        do {
            try manager.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            if source.path != binary {
                try? manager.removeItem(atPath: binary)
                try manager.copyItem(at: source, to: URL(fileURLWithPath: binary))
            }
            try manager.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: binary)

            let configDir = "/Library/Application Support/DisplayAudioFix"
            try manager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            let configPath = configDir + "/config.json"
            if !manager.fileExists(atPath: configPath) {
                let data = try JSONEncoder.pretty.encode(Configuration())
                try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            }
            try manager.createDirectory(atPath: "/var/db/displayaudiofix", withIntermediateDirectories: true)
            if !manager.fileExists(atPath: AppLogger.systemLogPath) {
                manager.createFile(atPath: AppLogger.systemLogPath, contents: nil, attributes: [.posixPermissions: 0o644])
            }
            try daemonPlist.data(using: .utf8)!.write(to: URL(fileURLWithPath: plist), options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: plist)
        } catch {
            fputs("install failed: \(error)\n", stderr)
            exit(1)
        }
        _ = ProcessRunner.run("/bin/launchctl", ["bootout", "system/\(label)"])
        // Do not leave a per-user watcher racing the newly installed system
        // daemon against the same CoreAudio device.
        if let uid = ProcessInfo.processInfo.environment["SUDO_UID"], uid != "0" {
            _ = ProcessRunner.run("/bin/launchctl", ["bootout", "gui/\(uid)/com.displayaudiofix.agent"])
        }
        if let user = ProcessInfo.processInfo.environment["SUDO_USER"], !user.isEmpty {
            if let userHome = NSHomeDirectoryForUser(user), !userHome.isEmpty {
                try? manager.removeItem(atPath: userHome + "/Library/LaunchAgents/com.displayaudiofix.agent.plist")
            }
        }
        let loaded = ProcessRunner.run("/bin/launchctl", ["bootstrap", "system", plist])
        guard loaded.status == 0 else {
            fputs("launchctl bootstrap failed: \(loaded.output)\n", stderr)
            exit(1)
        }
        _ = ProcessRunner.run("/bin/launchctl", ["kickstart", "-k", "system/\(label)"])
        print("DisplayAudioFix installed and running. Configuration: \(Configuration.configurationPath)")
        exit(0)
    }

    static func uninstall() -> Never {
        ensureRoot(command: "uninstall")
        _ = ProcessRunner.run("/bin/launchctl", ["bootout", "system/\(label)"])
        for path in [plist, binary, "/var/db/displayaudiofix/state.json"] {
            try? FileManager.default.removeItem(atPath: path)
        }
        print("DisplayAudioFix daemon, binary, and state removed.")
        print("Configuration and logs were retained for recovery/audit:")
        print("  \(Configuration.configurationPath)")
        print("  \(AppLogger.systemLogPath) and .1")
        exit(0)
    }

    private static func ensureRoot(command: String) {
        if geteuid() == 0 { return }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let result = ProcessRunner.run("/usr/bin/sudo", [executable, command], passthrough: true)
        exit(result.status)
    }

    private static var daemonPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(binary)</string><string>watch</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
          <key>ThrottleInterval</key><integer>10</integer>
          <key>StandardOutPath</key><string>/var/log/displayaudiofix-launchd.log</string>
          <key>StandardErrorPath</key><string>/var/log/displayaudiofix-launchd.log</string>
        </dict>
        </plist>
        """
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
