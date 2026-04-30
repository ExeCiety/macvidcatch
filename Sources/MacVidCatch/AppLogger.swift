import Foundation

enum AppLogger {
    static var logsDirectory: URL {
        let url = AppSupport.directory.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var appLogURL: URL { logsDirectory.appendingPathComponent("app.log") }

    static func jobLogURL(for id: UUID) -> URL {
        logsDirectory.appendingPathComponent("download-\(id.uuidString).log")
    }

    static func log(_ message: String, jobID: UUID? = nil) {
        let line = "[\(timestamp())] \(message)\n"
        append(line, to: appLogURL)
        if let jobID { append(line, to: jobLogURL(for: jobID)) }
    }

    static func writeJobOutput(_ output: String, jobID: UUID) {
        guard !output.isEmpty else { return }
        append("\n--- yt-dlp output ---\n\(output)\n--- end output ---\n", to: jobLogURL(for: jobID))
    }

    private static func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
