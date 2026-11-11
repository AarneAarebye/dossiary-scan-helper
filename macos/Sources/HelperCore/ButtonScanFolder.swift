import Foundation

public struct ButtonScanSaveError: LocalizedError, Equatable, Sendable {
    /// A system `localizedDescription`, never a literal of ours.
    public let reason: String
    public var errorDescription: String? { reason }
}

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
    /// Test seam: called with the temp file and the chosen target just before the move.
    var beforeMove: (@Sendable (URL, URL) -> Void)?

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

    /// Writes `data` as a new file named after `name` in `target` (default: the button-scan folder) and returns its
    /// URL; never overwrites. `extensions` are the suffixes a name may keep (see `safeName`).
    public func save(_ data: Data, named name: String, into target: URL? = nil, extensions: [String] = ["pdf"]) throws -> URL {
        try lock.withLock {
            let fm = FileManager.default
            let folder = target ?? url
            let safe = Self.safeName(name, extensions: extensions)
            let stem = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
            var temp: URL?
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let tmp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")   // dot-prefixed: a watched folder never shows it
                temp = tmp
                try Data().write(to: tmp)   // a system error with its own description when it can't be created
                let handle = try FileHandle(forWritingTo: tmp)
                do {
                    try handle.write(contentsOf: data)
                    try handle.synchronize()   // on disk before it gets its final name
                    try handle.close()
                } catch { try? handle.close(); throw error }
                var n = 1
                while true {
                    let candidate = n == 1 ? safe : "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
                    let target = folder.appendingPathComponent(candidate)
                    if !fm.fileExists(atPath: target.path) {
                        beforeMove?(tmp, target)
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
                if let error = error as? ButtonScanSaveError { throw error }
                throw ButtonScanSaveError(reason: error.localizedDescription)
            }
        }
    }

    /// Pure: the safe file name for a server-supplied name. Keeps the last path component, removes control and
    /// format characters (Cc, Cf), turns ":" into "-", trims blanks, never starts with ".", ends in one of
    /// `extensions` (the first one is appended when none matches; `["pdf"]` by default) and is at most 200 UTF-8
    /// bytes (cut on a character boundary); an empty result becomes "scan.<first extension>".
    public static func safeName(_ name: String, extensions: [String] = ["pdf"]) -> String {
        var s = name.unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
            .map { String($0) }.joined()
        s = s.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        s = s.replacingOccurrences(of: ":", with: "-")
        while true {
            let before = s
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasPrefix(".") { s.removeFirst() }
            if s == before { break }
        }
        let first = extensions.first ?? "pdf"
        if s.isEmpty { return "scan.\(first)" }
        let kept = extensions.first { s.lowercased().hasSuffix(".\($0)") } ?? first
        if !s.lowercased().hasSuffix(".\(kept)") { s += ".\(kept)" }
        if s.utf8.count > 200 {
            let suffixLength = kept.count + 1               // extensions are ASCII
            let suffix = String(s.suffix(suffixLength))
            var base = String(s.dropLast(suffixLength))
            while base.utf8.count + suffix.utf8.count > 200 { base.removeLast() }
            s = base + suffix
        }
        return s
    }
}
