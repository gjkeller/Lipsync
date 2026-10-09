import Foundation
import os

/// Logs to the unified log and to ~/Library/Logs/Lipsync/Lipsync.log, so a problem can be
/// diagnosed from a file after the fact.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lipsync", category: "app")
    private static let queue = DispatchQueue(label: "lipsync.log", qos: .utility)
    private static let maxBytes = 5 * 1024 * 1024

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lipsync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let fileURL = directory.appendingPathComponent("Lipsync.log")

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func debug(_ message: String) {
        #if DEBUG
        write("DEBUG", message)
        #endif
    }

    private static func write(_ level: String, _ message: String) {
        if level == "WARN" {
            logger.warning("\(message, privacy: .public)")
        } else {
            logger.info("\(message, privacy: .public)")
        }
        let stamp = Date()
        queue.async {
            let line = "\(stamp.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))) \(level) \(message)\n"
            append(line)
        }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? Int, size > maxBytes {
            let old = directory.appendingPathComponent("Lipsync.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
