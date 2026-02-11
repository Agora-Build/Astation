import Foundation

/// File-based logger for Astation.
/// Writes to ~/Library/Logs/Astation/astation.log and also prints to stdout.
/// Captures C FFI stderr output by redirecting stderr to the same log file.
enum Log {
    private static let logDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/Astation")
    }()

    static let logFile: URL = logDir.appendingPathComponent("astation.log")

    private static var fileHandle: FileHandle?
    private static var originalStderr: Int32 = -1

    /// Set up file logging. Call once at startup before anything else.
    /// - Rotates log if > 2 MB (keeps one .old backup)
    /// - Redirects stderr to log file so C FFI output is captured
    static func setup() {
        let fm = FileManager.default
        // Ensure directory exists
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)

        // Rotate if too large (> 2 MB)
        if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size > 2_000_000 {
            let oldFile = logDir.appendingPathComponent("astation.old.log")
            try? fm.removeItem(at: oldFile)
            try? fm.moveItem(at: logFile, to: oldFile)
        }

        // Create file if needed
        if !fm.fileExists(atPath: logFile.path) {
            fm.createFile(atPath: logFile.path, contents: nil)
        }

        fileHandle = FileHandle(forWritingAtPath: logFile.path)
        fileHandle?.seekToEndOfFile()

        // Redirect stderr (C FFI output) to the log file
        originalStderr = dup(STDERR_FILENO)
        if let fd = fileHandle?.fileDescriptor {
            dup2(fd, STDERR_FILENO)
        }

        // Write startup marker
        let ts = ISO8601DateFormatter().string(from: Date())
        let marker = "\n========== Astation started at \(ts) ==========\n"
        writeRaw(marker)
    }

    // MARK: - Public API

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "INFO", message: message, file: file, line: line)
    }

    static func warn(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "WARN", message: message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "ERROR", message: message, file: file, line: line)
    }

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "DEBUG", message: message, file: file, line: line)
    }

    // MARK: - Internal

    private static func log(level: String, message: String, file: String, line: Int) {
        let ts = timestamp()
        let source = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let formatted = "\(ts) [\(level)] [\(source):\(line)] \(message)\n"

        // Write to log file
        writeRaw(formatted)

        // Also print to stdout (visible when running from terminal)
        if originalStderr >= 0 {
            // Write to original stderr so it shows in terminal too
            formatted.utf8CString.withUnsafeBufferPointer { buf in
                let count = buf.count - 1 // exclude null terminator
                if count > 0 {
                    write(originalStderr, buf.baseAddress, count)
                }
            }
        }
    }

    private static func writeRaw(_ string: String) {
        if let data = string.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }
}
