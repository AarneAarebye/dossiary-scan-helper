import Testing
@testable import HelperCore

@Test func defaults() throws {
    #expect(try CommandLineOptions.parse([]) == CommandLineOptions())
    #expect(CommandLineOptions().port == 8766)
}

@Test func flags() throws {
    let options = try CommandLineOptions.parse(["--fake-scanners", "--headless", "--port", "9000"])
    #expect(options.fakeScanners && options.headless && options.port == 9000)
    #expect(try CommandLineOptions.parse(["--version"]).showVersion)
    #expect(try CommandLineOptions.parse(["-h"]).showHelp)
    #expect(try CommandLineOptions.parse(["-psn_0_12345"]) == CommandLineOptions())
}

@Test func badArguments() {
    for arguments in [["--port"], ["--port", "0"], ["--port", "65536"], ["--port", "x"], ["--host", "0.0.0.0"], ["extra"]] {
        #expect(throws: UsageError.self) { try CommandLineOptions.parse(arguments) }
    }
}
