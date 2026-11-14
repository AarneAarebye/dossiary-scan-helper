import AppKit
import HelperCore

/// Hands saved scans to Dossiary for Mac with the system's open-documents event. No custom URL scheme: a web page could trigger one.
enum DossiaryHandOver {
    static let bundleID = "com.aarneaarebye.dossiary-mac"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var isInstalled: Bool { appURL != nil }

    static func send(_ files: [URL]) async -> HandOverResult {
        guard let app = appURL else { return .notInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false      // the helper does not steal the focus
        do {
            _ = try await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration)
            return .sent
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
