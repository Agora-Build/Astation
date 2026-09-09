import Foundation
import Darwin

struct ADBCommandResult {
    let output: String
    let status: Int32
}

/// Cancellation is shared with the worker without accessing Process from two threads.
private final class ADBCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct ADBClient {
    let executable: String

    static func discover(saved: String?) -> String? {
        let environment = ProcessInfo.processInfo.environment
        var paths: [String] = []
        // An explicitly selected SDK must not silently switch to another installation.
        if let saved, !saved.isEmpty {
            return FileManager.default.isExecutableFile(atPath: saved) ? saved : nil
        }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key] { paths.append(root + "/platform-tools/adb") }
        }
        paths += [NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        paths += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/adb" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func localEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        for key in ["ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_PORT", "ANDROID_ADB_SERVER_ADDRESS", "ANDROID_SERIAL", "ADB_TRACE"] {
            result.removeValue(forKey: key)
        }
        return result
    }

    static func protocolVersion(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let prefix = "Android Debug Bridge version 1.0."
            if line.hasPrefix(prefix) { return Int(line.dropFirst(prefix.count)) }
        }
        return nil
    }

    func run(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 10) async throws -> ADBCommandResult {
        let cancellation = ADBCommandCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try Self.execute(executable: executable, arguments: arguments, input: input, timeout: timeout, cancellation: cancellation)
            }.value
        }, onCancel: { cancellation.cancel() })
    }

    private static func execute(executable: String, arguments: [String], input: String?, timeout: TimeInterval, cancellation: ADBCommandCancellation) throws -> ADBCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-H", "127.0.0.1", "-P", "5037"] + arguments
        process.environment = localEnvironment(ProcessInfo.processInfo.environment)
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = stdin
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? stdin.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
        }
        if cancellation.isCancelled { throw CancellationError() }
        try process.run()
        try? output.fileHandleForWriting.close()
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var failure: Error?
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
            if cancellation.isCancelled { failure = CancellationError(); break }
            if data.count > 1_048_576 { failure = AndroidSharingError.message("ADB output exceeded its limit."); break }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = AndroidSharingError.message("ADB command timed out."); break }
            if count <= 0 && !process.isRunning { break }
            if count <= 0 { usleep(20_000) }
        }
        if let failure {
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            throw failure
        }
        process.waitUntilExit()
        return ADBCommandResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }
}
