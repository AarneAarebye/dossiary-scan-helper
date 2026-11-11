import Foundation

public enum ProfileScanOutcome: Equatable, Sendable {
    /// `searchable` is nil when no text recognition was asked for, true when every file got its text layer,
    /// false when at least one stayed a plain scan.
    case saved(files: [URL], pages: Int, searchable: Bool?)
    /// Something went wrong but usable pages were saved.
    case partial(files: [URL], message: String)
    case failed(String)
}

/// Runs a scan profile: scan through the router (so exactly like a scan from Dossiary), wait for each file's text
/// recognition, save the files in the profile's folder. One profile scan at a time.
public final class ProfileScanRunner: @unchecked Sendable {
    private static let extensions = ["pdf", "jpg", "png"]

    private let router: Router
    private let writer: ButtonScanFolder
    private let clock: @Sendable () -> Date
    private let ocrPollSeconds: Double
    private let ocrGiveUpSeconds: Double
    private let lock = NSLock()
    private var running: String?

    /// Called, on any thread, when a profile scan starts and when it ends (the menu refreshes itself).
    public var onChange: (@Sendable () -> Void)?

    public init(router: Router, writer: ButtonScanFolder, clock: @escaping @Sendable () -> Date = Date.init,
                ocrPollSeconds: Double = 2, ocrGiveUpSeconds: Double = 600) {
        self.router = router; self.writer = writer; self.clock = clock
        self.ocrPollSeconds = ocrPollSeconds; self.ocrGiveUpSeconds = ocrGiveUpSeconds
    }

    public var runningProfileID: String? { lock.withLock { running } }
    public var isRunning: Bool { runningProfileID != nil }

    public func run(_ profile: ScanProfile) async -> ProfileScanOutcome {
        guard begin(profile.id) else { return .failed("Another profile scan is still running.") }
        onChange?()
        defer { end(); onChange?() }
        do {
            guard let scanner = await router.offeredScanners().first(where: { $0.id == profile.scannerID }) else {
                return .failed("\(profile.scannerName) isn't available right now.")
            }
            let fitted = ScanProfileRules.normalized(profile, for: scanner)
            let (status, payload) = try await router.performScan(ScanProfileRules.requestBody(fitted))
            guard status == 200 else { return .failed(payload["message"] as? String ?? "The scan failed.") }
            guard let entries = payload["files"] as? [[String: Any]], !entries.isEmpty else {
                return .failed(payload["message"] as? String ?? "The scanner returned no pages.")
            }
            let stamp = Self.stamp(clock())
            var saved: [URL] = []
            var pages = 0
            var allSearchable = true
            for (index, entry) in entries.enumerated() {
                guard var bytes = Data(base64Encoded: entry["data"] as? String ?? "") else {
                    return .failed("The scan couldn't be read.")
                }
                if fitted.ocr, let job = entry["ocrJob"] as? String {
                    if let searchable = await searchableCopy(job) { bytes = searchable } else { allSearchable = false }
                } else if fitted.ocr {
                    allSearchable = false
                }
                let ext = (entry["name"] as? String).map { ($0 as NSString).pathExtension.lowercased() }
                    .flatMap { Self.extensions.contains($0) ? $0 : nil } ?? "pdf"
                let suffix = entries.count > 1 ? "_\(index + 1)" : ""
                let url = try writer.save(bytes, named: "scan_\(stamp)\(suffix).\(ext)",
                                          into: URL(fileURLWithPath: fitted.destination, isDirectory: true),
                                          extensions: Self.extensions)
                saved.append(url)
                pages += entry["pages"] as? Int ?? 1
            }
            if payload["ok"] as? Bool == false {
                return .partial(files: saved, message: payload["message"] as? String ?? "The scan was incomplete.")
            }
            return .saved(files: saved, pages: pages, searchable: fitted.ocr ? allSearchable : nil)
        } catch let error as ProtocolError {
            return .failed(error.message)
        } catch let error as ButtonScanSaveError {
            return .failed(error.reason)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The searchable PDF for an OCR job, or nil when it failed or took longer than the give-up time (the plain scan
    /// is then kept). A network scanner that can't be reached for a moment (503) is retried until then.
    private func searchableCopy(_ job: String) async -> Data? {
        var waited = 0.0
        while true {
            let (status, body) = await router.performOCR(job)
            switch status {
            case 200:
                guard let files = body["files"] as? [[String: Any]], let first = files.first,
                      let data = Data(base64Encoded: first["data"] as? String ?? "") else { return nil }
                return data
            case 202, 503:
                break
            default:
                return nil
            }
            if waited >= ocrGiveUpSeconds { return nil }
            try? await Task.sleep(nanoseconds: UInt64(ocrPollSeconds * 1_000_000_000))
            waited += ocrPollSeconds
        }
    }

    private func begin(_ id: String) -> Bool {
        lock.withLock {
            guard running == nil else { return false }
            running = id
            return true
        }
    }

    private func end() { lock.withLock { running = nil } }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}
