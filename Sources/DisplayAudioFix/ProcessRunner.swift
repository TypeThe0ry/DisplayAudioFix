import Darwin
import Foundation

enum ProcessRunner {
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        passthrough: Bool = false,
        timeout: TimeInterval? = nil
    ) -> (status: Int32, output: String) {
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
            if let timeout {
                let exited = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    exited.signal()
                }
                if exited.wait(timeout: .now() + max(timeout, 0.1)) == .timedOut {
                    // BetterDisplay's integration helper is an external
                    // child process. Never let a wedged CLI block recovery;
                    // terminate only this child and report a bounded failure.
                    process.terminate()
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    return (-2, "process timed out after \(timeout)s")
                }
            } else {
                process.waitUntilExit()
            }
            let data = passthrough ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
