import Foundation

public struct UsageError: Error { public let message: String }

public struct CommandLineOptions: Equatable {
    public var fakeScanners = false
    public var headless = false
    public var port: UInt16 = 8766
    public var showVersion = false
    public var showHelp = false

    public init() {}

    public static let usage = """
        Usage: dossiary-scan-helper [--fake-scanners] [--headless] [--port N]
          --fake-scanners  the protocol's seven fake scanners instead of real ones (testing only;
                           pairing code 000000)
          --headless       no menu bar icon; log to the terminal too (CI and development)
          --port N         listen on 127.0.0.1:N instead of 8766
          --version, --help
        """

    public static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        var options = CommandLineOptions()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--fake-scanners": options.fakeScanners = true
            case "--headless": options.headless = true
            case "--version": options.showVersion = true
            case "-h", "--help": options.showHelp = true
            case "--port":
                guard let value = rest.popFirst(), let port = Int(value), (1...65535).contains(port) else {
                    throw UsageError(message: "--port needs a number from 1 to 65535.")
                }
                options.port = UInt16(port)
            default:
                if argument.hasPrefix("-psn_") { continue }  // added by older Launch Services
                throw UsageError(message: "Unknown argument: \(argument)")
            }
        }
        return options
    }
}
