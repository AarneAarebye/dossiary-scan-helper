import Foundation
import HelperCore

let options: CommandLineOptions
do {
    options = try CommandLineOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as UsageError {
    FileHandle.standardError.write(Data("\(error.message)\n\(CommandLineOptions.usage)\n".utf8))
    exit(2)
}
if options.showVersion { print("dossiary-scan-helper \(HelperVersion.string)"); exit(0) }
if options.showHelp { print(CommandLineOptions.usage); exit(0) }

Log.shared.echoToStderr = options.headless
let runtime: HelperRuntime
do {
    runtime = try HelperRuntime(options: options)
    try runtime.start()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
print("Dossiary Scan Helper on http://127.0.0.1:\(options.port)\(options.fakeScanners ? " (fake scanners, pairing code 000000)" : ""). Ctrl+C stops it.")
RunLoop.main.run()
