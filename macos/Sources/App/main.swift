import AppKit
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
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

/// SIGTERM (kill, launchd) and SIGINT (Ctrl+C) quit the same careful way as the menu's Quit.
var quitSignalSources: [DispatchSourceSignal] = []
func onQuitSignal(_ handler: @escaping () -> Void) {
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        quitSignalSources.append(source)
    }
}

if options.headless {
    onQuitSignal { Task { await runtime.stop(); exit(0) } }  // before start, so no signal arrives unhandled
    do { try runtime.start() } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
    print("Dossiary Scan Helper on http://127.0.0.1:\(options.port)\(options.fakeScanners ? " (fake scanners, pairing code 000000)" : ""). Ctrl+C stops it.")
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(runtime: runtime)
    app.delegate = delegate
    onQuitSignal { NSApp.terminate(nil) }
    withExtendedLifetime(delegate) { app.run() }
}
