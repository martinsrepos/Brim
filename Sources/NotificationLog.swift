import AppKit

/// A plain-text diary of what the notification mirror sees, for working out
/// why a notification didn't show. Menu bar > Brim > Notification Log… opens it
/// in Console.
///
/// It records which app sent each notification, its title (shortened), the
/// length of its message (never the message itself), and what Brim did with
/// it. The file lives in ~/Library/Logs/Brim and starts over past 2 MB.
@MainActor
enum NotificationLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Brim/Notifications.log")

    private static var handle: FileHandle?

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ line: String) {
        guard let data = "\(timestamp.string(from: Date()))  \(line)\n".data(using: .utf8) else { return }
        do {
            if handle == nil { handle = try openFile() }
            try handle?.seekToEnd()
            try handle?.write(contentsOf: data)
        } catch {
            handle = nil
        }
    }

    /// A title cut short, so the log stays readable and holds little personal text.
    static func short(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "-" }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 50 ? "\"\(flat.prefix(50))…\"" : "\"\(flat)\""
    }

    static func open() {
        write("--- log opened ---")
        NSWorkspace.shared.open(url)
    }

    private static func openFile() throws -> FileHandle {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if !manager.fileExists(atPath: url.path) || size > 2_000_000 {
            manager.createFile(atPath: url.path, contents: nil)
        }
        return try FileHandle(forWritingTo: url)
    }
}
