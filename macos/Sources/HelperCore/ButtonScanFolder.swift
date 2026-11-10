import Foundation

public struct ButtonScanSaveError: Error, Equatable, Sendable { public let reason: String }

/// Where picked-up button scan PDFs are saved: a folder remembered in UserDefaults (default ~/Documents/Scans).
public final class ButtonScanFolder: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents").appendingPathComponent("Scans")
    }

    private let defaults: UserDefaults
    private let key: String
    private let fallback: URL
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "buttonScanFolder",
                fallback: URL = ButtonScanFolder.defaultURL) {
        self.defaults = defaults; self.key = key; self.fallback = fallback
    }

    /// The chosen folder or the fallback.
    public var url: URL {
        if let path = defaults.string(forKey: key), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return fallback
    }

    public func choose(_ url: URL) { defaults.set(url.path, forKey: key) }

    /// Writes `data` as a new file named after `name` in the folder and returns its URL; never overwrites.
    public func save(_ data: Data, named name: String) throws -> URL {
        try lock.withLock {
            let fm = FileManager.default
            let folder = url
            let safe = Self.safeName(name)
            let stem = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
            var temp: URL?
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let tmp = folder.appendingPathComponent("\(UUID().uuidString).tmp")
                temp = tmp
                try data.write(to: tmp)
                var n = 1
                while true {
                    let candidate = n == 1 ? safe : "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
                    let target = folder.appendingPathComponent(candidate)
                    if !fm.fileExists(atPath: target.path) {
                        do {
                            try fm.moveItem(at: tmp, to: target)   // fails if the target appeared meanwhile
                            return target
                        } catch where fm.fileExists(atPath: target.path) {
                            // taken by someone else: try the next name
                        }
                    }
                    n += 1
                }
            } catch {
                if let temp { try? fm.removeItem(at: temp) }
                throw ButtonScanSaveError(reason: error.localizedDescription)
            }
        }
    }

    /// Pure: the safe file name for a server-supplied name.
    public static func safeName(_ name: String) -> String {
        var s = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map { String($0) }.joined()
        s = s.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        s = s.replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "scan.pdf" }
        if !s.lowercased().hasSuffix(".pdf") { s += ".pdf" }
        if s.count > 120 { s = String(s.dropLast(4).prefix(116)) + ".pdf" }
        return s
    }
}
