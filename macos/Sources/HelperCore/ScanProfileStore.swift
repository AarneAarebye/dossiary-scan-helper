import Foundation

/// The scan profiles (profiles.json in Application Support); fileURL nil keeps them in memory.
public final class ScanProfileStore: @unchecked Sendable {
    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dossiary-scan-helper")
            .appendingPathComponent("profiles.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var items: [ScanProfile] = []

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([ScanProfile].self, from: data) {
            items = saved
        } else {
            // Never lose what a person typed: keep the unreadable file next to the new, empty one.
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("profiles.json.unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    public var profiles: [ScanProfile] { lock.withLock { items } }

    public func profile(id: String) -> ScanProfile? { lock.withLock { items.first { $0.id == id } } }

    /// Adds the profile, or replaces the one with the same id.
    public func save(_ profile: ScanProfile) throws {
        try lock.withLock {
            if let index = items.firstIndex(where: { $0.id == profile.id }) { items[index] = profile }
            else { items.append(profile) }
            try write()
        }
    }

    public func remove(id: String) throws {
        try lock.withLock {
            items.removeAll { $0.id == id }
            try write()
        }
    }

    /// Call with the lock held.
    private func write() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: fileURL, options: .atomic)
    }
}
