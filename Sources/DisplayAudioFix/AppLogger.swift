import Foundation

final class AppLogger {
    static let shared = AppLogger()
    static let systemLogPath = "/var/log/displayaudiofix.log"

    private let lock = NSLock()
    private let formatter: DateFormatter
    private let maxBytes: UInt64 = 2 * 1024 * 1024
    private var requestedPath: String?

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
    }

    func configure(path: String) {
        lock.lock()
        requestedPath = path
        lock.unlock()
    }

    func log(_ message: String, alsoPrint: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let path = resolvedPath()
        rotateIfNeeded(path)
        let data = Data(line.utf8)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                if alsoPrint { fputs(line, stderr) }
            }
        } else if alsoPrint {
            fputs(line, stderr)
        }
        if alsoPrint { fputs(line, stdout) }
    }

    private func resolvedPath() -> String {
        if let requestedPath { return requestedPath }
        if geteuid() == 0 { return Self.systemLogPath }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DisplayAudioFix", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("displayaudiofix.log").path
    }

    private func rotateIfNeeded(_ path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber,
              size.uint64Value >= maxBytes else { return }
        let rotated = path + ".1"
        try? FileManager.default.removeItem(atPath: rotated)
        try? FileManager.default.moveItem(atPath: path, toPath: rotated)
    }
}

final class StateStore {
    private let lock = NSLock()
    private let path: String

    init() {
        let systemPath = "/var/db/displayaudiofix/state.json"
        if geteuid() == 0 || FileManager.default.isReadableFile(atPath: systemPath) {
            path = systemPath
        } else {
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/DisplayAudioFix/state.json").path
        }
    }

    func load() -> PersistentState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let state = try? JSONDecoder().decode(PersistentState.self, from: data) else {
            return PersistentState()
        }
        return state
    }

    func save(_ state: PersistentState) {
        lock.lock(); defer { lock.unlock() }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
