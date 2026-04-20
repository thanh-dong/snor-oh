import Foundation

/// Safe wrapper around `Process` that avoids the classic pipe-buffer deadlock.
///
/// **The trap:** macOS pipes have a 64 KB in-kernel buffer. If you call
/// `waitUntilExit()` before draining the stdout pipe, any child that writes
/// >64 KB blocks on `write()`, can't exit, and `waitUntilExit()` hangs forever
/// — freezing whichever thread called it. We hit this at launch with
/// `ps -axo` on a busy Mac (v0.6.1/v0.6.3 regression).
///
/// Always read the pipe BEFORE waiting — `readDataToEndOfFile` drains bytes as
/// they arrive, so the child never blocks on its write, exits cleanly, and
/// the subsequent `waitUntilExit()` returns immediately.
enum ProcessRunner {
    struct Result {
        let exitCode: Int32
        let stdout: Data
    }

    /// Runs `launchPath` with `arguments`, captures stdout, discards stderr.
    /// Returns `nil` only if the process could not be launched.
    static func runCapture(launchPath: String, arguments: [String]) -> Result? {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Result(exitCode: task.terminationStatus, stdout: data)
    }

    /// Convenience: returns trimmed UTF-8 stdout on exit 0, `nil` otherwise.
    static func captureString(launchPath: String, arguments: [String]) -> String? {
        guard let r = runCapture(launchPath: launchPath, arguments: arguments),
              r.exitCode == 0 else { return nil }
        let raw = String(data: r.stdout, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
