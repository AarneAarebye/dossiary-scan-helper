import Foundation

/// Appends timestamped lines to ~/Library/Logs/dossiary-scan-helper/helper.log (rotated at 5 MB).
/// Never pass tokens, pairing codes or page data to it.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/dossiary-scan-helper/helper.log")
    }

    public var echoToStderr = false
    public let url: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public init(url: URL = Log.defaultURL, maxBytes: Int = 5_000_000) {
        self.url = url
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
    }

    public func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
