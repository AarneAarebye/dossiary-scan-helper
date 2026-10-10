import Foundation

/// The helper's parts, wired together. Shared by the menu bar app and --headless.
public final class HelperRuntime: @unchecked Sendable {
    public let options: CommandLineOptions
    public let backend: ScannerBackend
    public let pairing: PairingStore
    public let router: Router
    public let server: HTTPServer
    private let log: Log

    public init(options: CommandLineOptions, log: Log = .shared) throws {
        self.options = options
        self.log = log
        if options.fakeScanners {
            backend = FakeBackend()
            pairing = PairingStore(mode: .fake)
        } else {
            throw UsageError(message: "Real scanners arrive in a later build. Run with --fake-scanners.")
        }
        let write: @Sendable (String) -> Void = { [log] in log.write($0) }
        router = Router(backend: backend, pairing: pairing, log: write)
        server = HTTPServer(port: options.port, router: router, log: write)
    }

    public func start() throws {
        try server.start()
        log.write("Dossiary Scan Helper \(HelperVersion.string) listening on 127.0.0.1:\(options.port)"
                  + (options.fakeScanners ? " with fake scanners." : "."))
    }
}
