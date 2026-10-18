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

@Test func printMenuFlag() throws {
    #expect(try CommandLineOptions.parse(["--print-menu"]).printMenu)
    #expect(try CommandLineOptions.parse([]).printMenu == false)
}

@Test func cocoaLanguageArgumentsAreSkipped() throws {
    let options = try CommandLineOptions.parse(["--print-menu", "-AppleLanguages", "(hy)", "-AppleLocale", "hy_AM"])
    #expect(options.printMenu)
    #expect(throws: UsageError.self) { try CommandLineOptions.parse(["-AppleLanguages"]) }
}
