import Foundation

/// The helper's parts, wired together. Shared by the menu bar app and --headless.
public final class HelperRuntime: @unchecked Sendable {
    public let options: CommandLineOptions
    public let backend: ScannerBackend
    public let pairing: PairingStore
    public let ocrJobs: OcrJobQueue
    public let router: Router
    public let server: HTTPServer
    private let log: Log

    public init(options: CommandLineOptions, log: Log = .shared) throws {
        self.options = options
        self.log = log
        let write: @Sendable (String) -> Void = { [log] in log.write($0) }
        if options.fakeScanners {
            backend = FakeBackend()
            pairing = PairingStore(mode: .fake)
        } else {
            backend = ImageCaptureBackend(log: { [log] in log.write($0) })
            pairing = PairingStore(mode: .real(fileURL: PairingStore.defaultFileURL), log: { [log] in log.write($0) })
        }
        let ocrLanguages: [String]
        if options.fakeScanners {
            // Fake mode keeps its jobs in one fixed temporary folder, emptied at every start, so test runs
            // neither see each other's jobs nor pile up folders.
            let fakeRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("dossiary-scan-helper-fake-ocr", isDirectory: true)
            try? FileManager.default.removeItem(at: fakeRoot)
            ocrJobs = OcrJobQueue(root: fakeRoot, engine: FakeOcrEngine(), log: write)
            ocrLanguages = []
        } else {
            ocrJobs = OcrJobQueue(root: OcrJobQueue.defaultRoot, engine: VisionOcrEngine(), log: write)
            ocrLanguages = VisionOcrEngine.offeredCodes()
        }
        router = Router(backend: backend, pairing: pairing, ocrJobs: ocrJobs, ocrLanguages: ocrLanguages, log: write)
        server = HTTPServer(port: options.port, router: router, log: write)
    }

    public func start() throws {
        try server.start()
        Task { [ocrJobs] in await ocrJobs.start() }
        if let real = backend as? ImageCaptureBackend {
            if Thread.isMainThread { MainActor.assumeIsolated { real.start() } }
            else { DispatchQueue.main.async { real.start() } }
        }
        log.write("Dossiary Scan Helper \(HelperVersion.string) listening on 127.0.0.1:\(options.port)"
                  + (options.fakeScanners ? " with fake scanners." : "."))
    }

    /// Before quitting: leaves no scan running and no scanner session open.
    public func stop() async { await backend.stopScans() }

    /// Whether quitting now would leave a scanner session open (so `stop()` has something to do).
    @MainActor public var hasOpenScannerSessions: Bool { (backend as? ImageCaptureBackend)?.hasOpenSessions ?? false }
}
