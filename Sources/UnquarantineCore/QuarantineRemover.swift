import Darwin
import Foundation

struct CommandResult {
    let status: Int32
    let output: String
    let error: String
}

enum QuarantineRemover {
    /// Batch file checks in one lsof invocation. Device/inode matching also
    /// handles hard links and alternate names such as /var and /private/var.
    /// No directory traversal: app bundles bypass this check altogether.
    static func openFiles(_ targets: [DownloadTarget]) throws -> Set<FileIdentity> {
        guard !targets.isEmpty else { return [] }
        precondition(targets.allSatisfy { !$0.isApp })
        var busy: Set<FileIdentity> = []
        // Bound the command's argument size even during a large event burst.
        for offset in stride(from: 0, to: targets.count, by: 64) {
            let batch = targets[offset..<min(offset + 64, targets.count)]
            let result = try runCommand("/usr/sbin/lsof", ["-n", "-P", "-F0fDi", "--"] + batch.map { $0.url.path })
            // Exit status 1 with no diagnostics means no matching open files.
            guard (result.status == 0 || result.status == 1), result.error.isEmpty else {
                throw commandError("Could not check open files", result.error)
            }
            busy.formUnion(parseOpenFiles(result.output))
        }
        return busy
    }

    static func parseOpenFiles(_ output: String) -> Set<FileIdentity> {
        var identities: Set<FileIdentity> = []
        var device: UInt64?
        var inode: UInt64?
        func finishRecord() {
            if let device, let inode { identities.insert(FileIdentity(device: device, inode: inode)) }
        }
        for field in output.split(separator: "\0") {
            let field = field.trimmingCharacters(in: .newlines)
            switch field.first {
            case "p", "f":
                finishRecord()
                device = nil
                inode = nil
            case "D":
                let number = field.dropFirst()
                device = UInt64(number.hasPrefix("0x") ? number.dropFirst(2) : number, radix: 16)
            case "i":
                inode = UInt64(field.dropFirst())
            default: break
            }
        }
        finishRecord()
        return identities
    }

    static func remove(from url: URL) throws {
        // No recursion: for .app only the bundle directory is changed. -s avoids
        // following a symlink if the target was replaced since inspection.
        let result = try runCommand("/usr/bin/xattr", ["-d", "-s", "com.apple.quarantine", url.path])
        guard result.status == 0 else {
            // Another event/process may already have cleared or removed it.
            if !(try hasQuarantine(url)) { return }
            throw commandError("Could not remove quarantine", result.error)
        }
    }
}

/// Sleeps in the kernel until process exit, rather than polling isRunning.
/// Callers use a serial worker queue, so commands never overlap.
func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // Files avoid pipe-buffer deadlocks when lsof reports many open handles.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdout = directory.appendingPathComponent("stdout")
    let stderr = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdout.path, contents: nil)
    FileManager.default.createFile(atPath: stderr.path, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: stdout)
    let errorHandle = try FileHandle(forWritingTo: stderr)
    defer { try? outputHandle.close(); try? errorHandle.close() }
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        // Bound shutdown as well as execution; leave no timed-out child running.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw commandError("Command timed out", executable)
    }
    process.waitUntilExit()
    return CommandResult(
        status: process.terminationStatus,
        output: String(decoding: try Data(contentsOf: stdout), as: UTF8.self),
        error: String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
    )
}

private func commandError(_ message: String, _ detail: String) -> NSError {
    NSError(domain: "Unquarantine", code: 1, userInfo: [
        NSLocalizedDescriptionKey: detail.isEmpty ? message : "\(message): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))",
    ])
}
