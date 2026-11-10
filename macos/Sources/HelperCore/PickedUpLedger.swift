import Foundation

/// Remembers which button scans were saved (picked-up.json in Application Support); fileURL nil keeps them in memory.
public final class PickedUpLedger: @unchecked Sendable {
    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dossiary-scan-helper")
            .appendingPathComponent("picked-up.json")
    }

    private struct Entry: Codable { var file: String; var saved: Double }

    private let fileURL: URL?
    private let clock: @Sendable () -> Date
    private let retention: TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(fileURL: URL?, clock: @escaping @Sendable () -> Date = Date.init, retention: TimeInterval = 30 * 24 * 3600) {
        self.fileURL = fileURL; self.clock = clock; self.retention = retention
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    public func contains(_ id: String) -> Bool { lock.withLock { entries[id] != nil } }

    public func record(_ id: String, file: String) throws {
        try lock.withLock {
            let now = clock().timeIntervalSince1970
            entries = entries.filter { now - $0.value.saved <= retention }
            entries[id] = Entry(file: file, saved: now)
            try save()
        }
    }

    /// Call with the lock held.
    private func save() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}
