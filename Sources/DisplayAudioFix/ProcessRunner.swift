import Foundation

enum ProcessRunner {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], passthrough: Bool = false) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        if passthrough {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            process.standardInput = FileHandle.standardInput
        } else {
            process.standardOutput = pipe
            process.standardError = pipe
        }
        do {
            try process.run()
            let data = passthrough ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
